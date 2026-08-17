<?php

namespace CoverPlugin\Support;

/**
 * 从 MediaCover 平台拉取租户安全配置（如 kill_subscribe），带本地安全缓存与 HMAC 防篡改校验。
 * 租户在控制台调整开关后，约 TTL 秒内全局生效，无需修改 .env 或重启。
 */
class PlatformSettings
{
    // 兼容 PHP 7.0+: 移除 private 访问修饰符 (修复 V6-06)
    const TTL = 30; // 正常缓存有效秒数
    const FAIL_TTL = 30; // 平台异常时的负缓存秒数（防 PHP-FPM 请求放大）

    // 兼容 PHP 7.0+：不使用 PHP 7.4+ typed properties (修复 V3-07 / V5-09)
    private static $memCache = null;
    private static $memCacheExp = 0;

    /**
     * @return array
     */
    public static function resolve()
    {
        $panel = rtrim((string) self::env('COVER_PANEL_URL', ''), '/');
        $token = (string) self::env('COVER_PLUGIN_TOKEN', '');
        if ($panel === '' || $token === '' || !function_exists('curl_init')) {
            return array('kill_subscribe' => true, 'source' => 'env_default');
        }

        // 严格解析与校验 HTTPS Scheme 与 Host (修复 R-05)
        $parsed = parse_url($panel);
        $scheme = strtolower(isset($parsed['scheme']) ? $parsed['scheme'] : '');
        $host = strtolower(isset($parsed['host']) ? $parsed['host'] : '');
        $isLocal = ($host === 'localhost' || $host === '127.0.0.1' || $host === '::1');

        if (!$isLocal && $scheme !== 'https') {
            $panel = 'https://' . preg_replace('#^[a-zA-Z]+://#', '', $panel);
        }

        $now = time();

        // 1. 进程内内存缓存
        if (self::$memCache !== null && self::$memCacheExp > $now) {
            return array('kill_subscribe' => self::$memCache, 'source' => 'memory');
        }

        // 2. 本地持久化缓存读取：只接受站点私有 storage 中、当前 UID 拥有的 0600 regular file。
        $cacheFile = self::cachePath();
        if (is_string($cacheFile) && self::isTrustedCacheFile($cacheFile)) {
            $raw = @file_get_contents($cacheFile);
            if (is_string($raw) && $raw !== '') {
                $container = json_decode($raw, true);
                if (is_array($container) && isset($container['payload'], $container['sig'])) {
                    $calcSig = hash_hmac('sha256', (string) $container['payload'], $token);
                    if (hash_equals($calcSig, (string) $container['sig'])) {
                        $j = json_decode($container['payload'], true);
                        if (is_array($j) && isset($j['exp'], $j['kill_subscribe']) && (int) $j['exp'] > $now) {
                            $val = (bool) $j['kill_subscribe'];
                            self::$memCache = $val;
                            self::$memCacheExp = (int) $j['exp'];
                            $isNeg = isset($j['negative']) && $j['negative'] === true;
                            return array('kill_subscribe' => $val, 'source' => $isNeg ? 'neg_cache' : 'cache');
                        }
                    }
                }
            }
        }

        // 不可信/不可验证的缓存一律忽略，不 unlink 可能是 symlink 的路径，避免跟随链接修改外部文件。
        // 3. 请求平台 API
        $url = $panel . '/api/plugin/v1/settings';
        $ch = curl_init($url);
        curl_setopt_array($ch, array(
            CURLOPT_RETURNTRANSFER => true,
            CURLOPT_TIMEOUT => 2,
            CURLOPT_CONNECTTIMEOUT => 1,
            CURLOPT_HTTPHEADER => array(
                'Authorization: Plugin ' . $token,
                'Accept: application/json',
                'User-Agent: MediaCover-Plugin/1.2',
            ),
        ));
        $body = curl_exec($ch);
        $code = (int) curl_getinfo($ch, CURLINFO_HTTP_CODE);
        curl_close($ch);

        // 4. 平台异常处理：修复 V4-05 / V5-07 (真正严格 Fail-Closed: 无条件封锁，返回 true)
        if (!is_string($body) || $code !== 200) {
            self::writeSecureCache($cacheFile, true, $now + self::FAIL_TTL, $token, true);
            self::$memCache = true;
            self::$memCacheExp = $now + self::FAIL_TTL;
            return array('kill_subscribe' => true, 'source' => 'fail_closed_fallback');
        }

        $j = json_decode($body, true);
        // 严格要求 code 字段存在且全等为整数 0 (修复 V6-05)
        if (!is_array($j) || !array_key_exists('code', $j) || $j['code'] !== 0) {
            self::writeSecureCache($cacheFile, true, $now + self::FAIL_TTL, $token, true);
            self::$memCache = true;
            self::$memCacheExp = $now + self::FAIL_TTL;
            return array('kill_subscribe' => true, 'source' => 'fail_closed_fallback');
        }

        // 严格 JSON 布尔值校验 (修复 V4-07 / V5-08)
        $data = isset($j['data']) && is_array($j['data']) ? $j['data'] : array();
        $rawKill = isset($data['kill_subscribe']) ? $data['kill_subscribe'] : null;
        if ($rawKill === true || $rawKill === 1 || $rawKill === '1' || $rawKill === 'true') {
            $kill = true;
        } elseif ($rawKill === false || $rawKill === 0 || $rawKill === '0' || $rawKill === 'false') {
            $kill = false;
        } else {
            $kill = true;
        }

        // 5. 写入带签名的持久化缓存 (严格 0600 用户独占模式，拒绝 0666 / 0777)
        self::writeSecureCache($cacheFile, $kill, $now + self::TTL, $token, false);
        self::$memCache = $kill;
        self::$memCacheExp = $now + self::TTL;

        return array('kill_subscribe' => $kill, 'source' => 'platform');
    }

    public static function killSubscribeOn()
    {
        $res = self::resolve();
        return $res['kill_subscribe'];
    }

    /**
     * 安全持久化缓存：带 HMAC 签名与原子替换，权限严格为 0600
     */
    private static function writeSecureCache($path, $kill, $exp, $token, $isNeg)
    {
        if (!is_string($path) || $path === '') {
            return false;
        }
        $dir = dirname($path);
        if (!self::isTrustedStorageDir($dir)) {
            return false;
        }
        $payload = json_encode(array(
            'kill_subscribe' => (bool) $kill,
            'exp' => (int) $exp,
            'negative' => (bool) $isNeg,
            'fetched_at' => time(),
        ));
        $sig = hash_hmac('sha256', (string) $payload, $token);
        $container = json_encode(array(
            'payload' => $payload,
            'sig' => $sig,
        ));

        try {
            $suffix = bin2hex(random_bytes(16));
        } catch (\Exception $e) {
            return false;
        }
        $tmp = $dir . '/.settings_cache.' . getmypid() . '.' . $suffix;
        if (@file_put_contents($tmp, $container, LOCK_EX) === false || !@chmod($tmp, 0600)) {
            @unlink($tmp);
            return false;
        }
        if (!@rename($tmp, $path)) {
            @unlink($tmp);
            return false;
        }
        return self::isTrustedCacheFile($path);
    }

    private static function cachePath()
    {
        // 禁止可预测的公共 /tmp fallback；不可验证时直接不持久化，API 失败仍 fail-closed。
        $base = dirname(__DIR__, 2);
        $storageDir = $base . '/storage';
        if (self::isTrustedStorageDir($storageDir)) {
            return $storageDir . '/settings_cache.json';
        }
        return null;
    }

    private static function isTrustedStorageDir($dir)
    {
        if (!is_string($dir) || !is_dir($dir) || is_link($dir) || !function_exists('posix_geteuid')) {
            return false;
        }
        $uid = @posix_geteuid();
        $owner = @fileowner($dir);
        $perms = @fileperms($dir);
        return $owner !== false && $owner === $uid && $perms !== false && (($perms & 0777) === 0700) && is_writable($dir);
    }

    private static function isTrustedCacheFile($path)
    {
        if (!is_string($path) || !is_file($path) || is_link($path) || !function_exists('posix_geteuid')) {
            return false;
        }
        $owner = @fileowner($path);
        $perms = @fileperms($path);
        $dir = dirname($path);
        $uid = @posix_geteuid();
        return self::isTrustedStorageDir($dir)
            && $owner !== false && $owner === $uid
            && $perms !== false && (($perms & 0777) === 0600);
    }

    private static function env($key, $default = '')
    {
        $v = isset($_ENV[$key]) ? $_ENV[$key] : (isset($_SERVER[$key]) ? $_SERVER[$key] : getenv($key));
        if ($v === false || $v === null || $v === '') {
            return $default;
        }
        return (string) $v;
    }

    private static function envBool($key, $default)
    {
        $v = self::env($key, $default ? '1' : '0');
        return filter_var($v, FILTER_VALIDATE_BOOLEAN);
    }
}
