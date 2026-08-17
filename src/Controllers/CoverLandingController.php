<?php

namespace CoverPlugin\Controllers;

use Illuminate\Http\Request;

/**
 * Simple landing page: replace "copy subscribe" with Cover download + panel link.
 */
class CoverLandingController
{
    public function show(Request $request)
    {
        $panel = rtrim(env('COVER_PANEL_URL', ''), '/');
        $tenant = env('COVER_TENANT_ID', '');
        $board = env('COVER_BOARD_ID', '');
        $android = env('COVER_APP_ANDROID', '');
        $ios = env('COVER_APP_IOS', '');
        $name = env('APP_NAME', 'Cover');

        $login = $panel !== '' ? $panel . '/' : '#';
        if ($panel !== '' && ($tenant !== '' || $board !== '')) {
            // multi-v2 under one tenant: pass tenant_id + board_id
            $q = [];
            if ($tenant !== '') {
                $q[] = 'tenant_id=' . urlencode($tenant);
            }
            if ($board !== '') {
                $q[] = 'board_id=' . urlencode($board);
            }
            $login = $panel . '/?' . implode('&', $q);
        }

        $html = '<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"/>'
            . '<meta name="viewport" content="width=device-width,initial-scale=1"/>'
            . '<title>' . htmlspecialchars($name) . ' · 客户端</title>'
            . '<style>body{font-family:system-ui,sans-serif;max-width:520px;margin:40px auto;padding:0 16px;color:#0f172a}'
            . 'a.btn{display:inline-block;margin:8px 8px 0 0;padding:12px 16px;background:#2563eb;color:#fff;border-radius:8px;text-decoration:none;font-weight:600}'
            . 'a.sec{background:#334155}.mut{color:#64748b;font-size:14px;line-height:1.6}</style></head><body>'
            . '<h1>连接方式已升级</h1>'
            . '<p class="mut">本站已接入 Cover 安全入口。请使用官方客户端或用户中心登录，'
            . '<b>不再提供订阅链接 / Clash 配置</b>。</p>'
            . '<p><a class="btn" href="' . htmlspecialchars($login) . '">打开用户中心</a>';

        if ($android !== '') {
            $html .= '<a class="btn sec" href="' . htmlspecialchars($android) . '">Android 下载</a>';
        }
        if ($ios !== '') {
            $html .= '<a class="btn sec" href="' . htmlspecialchars($ios) . '">iOS 下载</a>';
        }

        $tag = $tenant;
        if ($board !== '') {
            $tag = trim($tenant . ' / board ' . $board);
        }
        $html .= '</p><p class="mut">登录账号与本站（v2board）注册邮箱、密码相同'
            . ($tag !== '' ? '（接入：' . htmlspecialchars($tag) . '）' : '')
            . '。线路由 Cover 节点层提供，不再使用订阅节点。</p></body></html>';

        return response($html, 200)->header('Content-Type', 'text/html; charset=utf-8');
    }
}
