<?php
/**
 * MediaCover 非侵入安全引导：由 public/index.php 自动 require。
 * - 递归安全解码与规范化路径，严密封杀订阅/节点导出（在请求到达框架前 404）
 * - 拦截 /cover 落地引导页（展示 App 下载指引）
 * - 所有正常原站业务（用户登录、注册、订单、支付、后台等）100% 透明原样放行
 *
 * 绝对零侵入，不留后门，不修改原站数据库与业务代码。
 */
if (defined('COVER_PLUGIN_BOOTSTRAPPED')) {
    return;
}
define('COVER_PLUGIN_BOOTSTRAPPED', true);

(function () {
    // 兼容 PHP 7.0+ 字符串函数
    if (!function_exists('str_starts_with')) {
        function str_starts_with($haystack, $needle) {
            return $needle === '' || strncmp($haystack, $needle, strlen($needle)) === 0;
        }
    }
    if (!function_exists('str_contains')) {
        function str_contains($haystack, $needle) {
            return $needle === '' || strpos($haystack, $needle) !== false;
        }
    }

    // 确定当前插件基础目录与 board 根目录
    $pluginDir = __DIR__;
    $srcDir = is_dir($pluginDir . '/Support') ? $pluginDir : $pluginDir . '/src';
    $boardRoot = dirname($srcDir, 2);
    if (!is_file($boardRoot . '/.env') && is_file(dirname($srcDir) . '/.env')) {
        $boardRoot = dirname($srcDir);
    }

    // 从 .env 安全读取 COVER_* 配置 (兼容 PHP 7.0+)
    $envFile = $boardRoot . '/.env';
    if (is_file($envFile)) {
        $lines = @file($envFile, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
        if (is_array($lines)) {
            foreach ($lines as $line) {
                $line = trim($line);
                if ($line === '' || $line[0] === '#' || strpos($line, '=') === false) {
                    continue;
                }
                $parts = explode('=', $line, 2);
                $k = trim($parts[0]);
                if ($k === '' || strpos($k, 'COVER_') !== 0) {
                    continue;
                }
                $v = isset($parts[1]) ? trim($parts[1]) : '';
                if (strlen($v) >= 2 && (($v[0] === '"' && substr($v, -1) === '"') || ($v[0] === "'" && substr($v, -1) === "'"))) {
                    $v = substr($v, 1, -1);
                }
                if (getenv($k) === false || getenv($k) === '') {
                    putenv("$k=$v");
                    $_ENV[$k] = $v;
                    $_SERVER[$k] = $v;
                }
            }
        }
    }

    $coverEnv = static function ($key, $default = '') {
        $v = isset($_ENV[$key]) ? $_ENV[$key] : (isset($_SERVER[$key]) ? $_SERVER[$key] : getenv($key));
        if ($v === false || $v === null || $v === '') {
            return $default;
        }
        return (string) $v;
    };

    // 1. 彻底解决 V9-01 & V10-01: 完整递归 URL 解码与残余编码/控制字符严格安全清洗
    $rawUri = isset($_SERVER['REQUEST_URI']) ? (string)$_SERVER['REQUEST_URI'] : '/';
    $rawPath = parse_url($rawUri, PHP_URL_PATH);
    $rawPath = is_string($rawPath) ? $rawPath : '/';

    // 循环解码直到完全稳定（上限 32 次）
    $decodedPath = $rawPath;
    $rounds = 0;
    while ($rounds < 32) {
        $next = rawurldecode($decodedPath);
        if ($next === $decodedPath) {
            break;
        }
        $decodedPath = $next;
        $rounds++;
    }

    // 解决 V10-01: 如果达到轮数上限后仍存在 %XX 编码残留，视为多重编码绕过攻击，直接 404 拒绝
    if (preg_match('#%[0-9a-fA-F]{2}#', $decodedPath)) {
        http_response_code(404);
        header('Content-Type: application/json; charset=utf-8');
        echo json_encode(array('message' => 'Not Found', 'code' => 404), JSON_UNESCAPED_UNICODE);
        exit;
    }

    $decodedPath = str_replace('\\', '/', $decodedPath);
    $decodedPath = preg_replace('#/+#', '/', $decodedPath);

    // 拦截异常空字节/控制字符
    if (strpos($decodedPath, "\0") !== false) {
        http_response_code(404);
        exit;
    }

    $pathLower = strtolower($decodedPath);
    $pathLower = preg_replace('#^/index\.php#', '', $pathLower);
    if ($pathLower === '' || $pathLower === false) {
        $pathLower = '/';
    }
    $pathLower = '/' . ltrim($pathLower, '/');
    if ($pathLower !== '/') {
        $pathLower = rtrim($pathLower, '/');
    }

    // 2. 检查订阅拦截开关
    $killOn = filter_var($coverEnv('COVER_KILL_SUBSCRIBE', '1'), FILTER_VALIDATE_BOOLEAN);
    $settingsFile = $srcDir . '/Support/PlatformSettings.php';
    if (is_file($settingsFile)) {
        require_once $settingsFile;
        if (class_exists('CoverPlugin\\Support\\PlatformSettings', false)
            || class_exists(\CoverPlugin\Support\PlatformSettings::class, false)) {
            try {
                $killOn = \CoverPlugin\Support\PlatformSettings::killSubscribeOn();
            } catch (\Throwable $e) {
                // keep default
            }
        }
    }

    if ($killOn) {
        $blockedExact = [
            '/api/v1/client/subscribe',
            '/api/v1/client/app/getconfig',
            '/api/v1/client/app/getversion',
            '/api/v1/server/uniproxy/config',
            '/api/v1/server/uniproxy/user',
            '/api/v1/server/uniproxy/push',
            '/subscribe',
        ];

        $deny = false;
        foreach ($blockedExact as $b) {
            if ($pathLower === $b || str_starts_with($pathLower, $b . '/')) {
                $deny = true;
                break;
            }
        }

        // 短链路径精确拦截（如 /s/xxx, /link/xxx）
        if (!$deny && (str_starts_with($pathLower, '/s/') || str_starts_with($pathLower, '/link/'))) {
            $deny = true;
        }

        // 深度模式匹配
        if (!$deny) {
            $checkStrings = [$pathLower, strtolower($rawUri)];
            $needles = ['subscribe', 'clash', 'shadowrocket', 'quantumult', 'uniproxy', 'getservers'];
            foreach ($checkStrings as $str) {
                foreach ($needles as $n) {
                    if (str_contains($str, $n)) {
                        if (str_contains($str, 'passport') || str_contains($str, 'admin')) {
                            if (!str_contains($str, 'subscribe') && !str_contains($str, 'clash') && !str_contains($str, 'uniproxy')) {
                                continue;
                            }
                        }
                        if (str_contains($str, 'client') || str_contains($str, 'subscribe') || str_contains($str, 'clash') || str_contains($str, 'uniproxy')) {
                            $deny = true;
                            break 2;
                        }
                    }
                }
            }
        }

        if ($deny) {
            http_response_code(404);
            header('Content-Type: application/json; charset=utf-8');
            echo json_encode([
                'message' => 'Not Found',
                'code' => 404,
                'data' => null,
                'hint' => 'Use MediaCover App / official portal. Subscription links are disabled.',
            ], JSON_UNESCAPED_UNICODE);
            exit;
        }
    }

    // 3. /cover 落地引导页（直接响应，不进入框架路由）
    $isCover = ($pathLower === '/cover');
    if ($isCover) {
        $panel = rtrim((string) $coverEnv('COVER_PANEL_URL', 'https://kaka2.lol'), '/');
        $parsed = parse_url($panel);
        $scheme = strtolower(isset($parsed['scheme']) ? $parsed['scheme'] : '');
        $host = strtolower(isset($parsed['host']) ? $parsed['host'] : '');
        $isLocal = ($host === 'localhost' || $host === '127.0.0.1' || $host === '::1');
        if (!$isLocal && $scheme !== 'https') {
            $panel = 'https://' . preg_replace('#^[a-zA-Z]+://#', '', $panel);
        }
        $tenant = (string) $coverEnv('COVER_TENANT_ID', '');
        $board = (string) $coverEnv('COVER_BOARD_ID', '');
        $android = (string) $coverEnv('COVER_APP_ANDROID', '');
        $ios = (string) $coverEnv('COVER_APP_IOS', '');

        $h = static function ($s) {
            return htmlspecialchars((string) $s, ENT_QUOTES | ENT_SUBSTITUTE, 'UTF-8');
        };

        $login = $panel !== '' ? $panel . '/' : '#';
        if ($panel !== '' && ($tenant !== '' || $board !== '')) {
            $q = [];
            if ($tenant !== '') {
                $q[] = 'tenant_id=' . rawurlencode($tenant);
            }
            if ($board !== '') {
                $q[] = 'board_id=' . rawurlencode($board);
            }
            $login = $panel . '/?' . implode('&', $q);
        }

        header('Content-Type: text/html; charset=utf-8');
        echo '<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"/><meta name="viewport" content="width=device-width,initial-scale=1"/>';
        echo '<title>MediaCover · 客户端连接引导</title><style>
body{margin:0;background:#070b14;color:#e8eef9;font-family:-apple-system,BlinkMacSystemFont,system-ui,sans-serif;min-height:100vh;display:flex;align-items:center;justify-content:center;padding:20px}
.card{max-width:480px;width:100%;background:#0d1526;border:1px solid rgba(148,163,184,.2);border-radius:18px;padding:28px 24px;box-shadow:0 12px 36px rgba(0,0,0,.4)}
h1{font-size:22px;margin:0 0 10px;font-weight:700}
.mut{color:#8b9bb8;font-size:14px;line-height:1.6;margin:0 0 20px}
.btns{display:flex;flex-wrap:wrap;gap:10px;margin-bottom:20px}
a.btn{display:inline-flex;align-items:center;justify-content:center;padding:12px 20px;background:#3b82f6;color:#fff;border-radius:10px;text-decoration:none;font-weight:600;font-size:14px;flex:1;min-width:140px}
a.btn.sec{background:#1e293b;border:1px solid rgba(148,163,184,.2)}
.note{border-top:1px solid rgba(148,163,184,.15);padding-top:16px;font-size:12px;color:#64748b;line-height:1.6}
</style></head><body><div class="card">';
        echo '<h1>连接方式已升级</h1>';
        echo '<p class="mut">本站已接入 MediaCover 安全连接架构。请使用官方客户端或控制台直接登录，<b>不再提供普通订阅链接与配置导出</b>。</p>';
        echo '<div class="btns"><a class="btn" href="' . $h($login) . '">打开用户中心</a>';
        if ($android !== '') {
            echo '<a class="btn sec" href="' . $h($android) . '">Android 下载</a>';
        }
        if ($ios !== '') {
            echo '<a class="btn sec" href="' . $h($ios) . '">iOS 下载</a>';
        }
        echo '</div>';
        echo '<div class="note">登录账号与本站注册邮箱、密码相同。全链路采用专属隐写加密中转，无需配置节点。</div>';
        echo '</div></body></html>';
        exit;
    }
})();
