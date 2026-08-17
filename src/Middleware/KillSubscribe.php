<?php

namespace CoverPlugin\Middleware;

use Closure;
use CoverPlugin\Support\PlatformSettings;
use Illuminate\Http\Request;

/**
 * Scheme A: optionally block legacy subscription / node-export surfaces.
 * 开关以 Cover 租户控制台为准（平台 API），本地 .env 仅作兜底。
 */
class KillSubscribe
{
    public function handle(Request $request, Closure $next)
    {
        $killOn = true;
        try {
            if (class_exists(PlatformSettings::class)) {
                $killOn = PlatformSettings::killSubscribeOn();
            } else {
                $killOn = filter_var(env('COVER_KILL_SUBSCRIBE', true), FILTER_VALIDATE_BOOLEAN);
            }
        } catch (\Throwable $e) {
            $killOn = filter_var(env('COVER_KILL_SUBSCRIBE', true), FILTER_VALIDATE_BOOLEAN);
        }
        if (!$killOn) {
            return $next($request);
        }

        $path = strtolower($request->path());
        $uri  = strtolower($request->getRequestUri());

        $blockedExact = [
            'api/v1/client/subscribe',
            'api/v1/client/app/getconfig',
            'api/v1/client/app/getversion',
            'api/v1/server/uniproxy/config',
            'api/v1/server/uniproxy/user',
            'api/v1/server/uniproxy/push',
            'subscribe',
        ];

        foreach ($blockedExact as $b) {
            if ($path === $b || str_starts_with($path, $b . '/')) {
                return $this->deny();
            }
        }

        if (str_starts_with($path, 's/') || str_starts_with($path, 'link/')) {
            return $this->deny();
        }

        $needles = ['subscribe', 'clash', 'shadowrocket', 'quantumult', 'uniproxy', 'getservers'];
        foreach ($needles as $n) {
            if (str_contains($path, $n) || str_contains($uri, $n)) {
                if (str_contains($path, 'passport') || str_contains($path, 'admin')) {
                    if (!str_contains($path, 'subscribe') && !str_contains($path, 'clash') && !str_contains($path, 'uniproxy')) {
                        continue;
                    }
                }
                if (str_contains($path, 'client') || str_contains($path, 'subscribe') || str_contains($path, 'clash') || str_contains($path, 'uniproxy')) {
                    return $this->deny();
                }
            }
        }

        return $next($request);
    }

    private function deny()
    {
        return response()->json([
            'message' => 'Not Found',
            'code' => 404,
            'data' => null,
            'hint' => 'Use Cover App / user portal. Subscription links are disabled by tenant settings.',
        ], 404);
    }
}
