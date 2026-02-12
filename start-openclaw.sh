#!/bin/bash
# Startup script for OpenClaw in Cloudflare Sandbox
# This script:
# 1. Restores config/workspace/skills from R2 via rclone (if configured)
# 2. Runs openclaw onboard --non-interactive to configure from env vars
# 3. Patches config for features onboard doesn't cover (channels, gateway auth)
# 4. Starts a background sync loop (rclone, watches for file changes)
# 5. Starts the gateway

set -e

if pgrep -f "openclaw gateway" > /dev/null 2>&1; then
    echo "OpenClaw gateway is already running, exiting."
    exit 0
fi

CONFIG_DIR="/root/.openclaw"
CONFIG_FILE="$CONFIG_DIR/openclaw.json"
WORKSPACE_DIR="/root/clawd"
SKILLS_DIR="/root/clawd/skills"
RCLONE_CONF="/root/.config/rclone/rclone.conf"
LAST_SYNC_FILE="/tmp/.last-sync"

echo "Config directory: $CONFIG_DIR"

mkdir -p "$CONFIG_DIR"

# ============================================================
# RCLONE SETUP
# ============================================================

r2_configured() {
    [ -n "$R2_ACCESS_KEY_ID" ] && [ -n "$R2_SECRET_ACCESS_KEY" ] && [ -n "$CF_ACCOUNT_ID" ]
}

R2_BUCKET="${R2_BUCKET_NAME:-moltbot-data}"

setup_rclone() {
    mkdir -p "$(dirname "$RCLONE_CONF")"
    cat > "$RCLONE_CONF" << EOF
[r2]
type = s3
provider = Cloudflare
access_key_id = $R2_ACCESS_KEY_ID
secret_access_key = $R2_SECRET_ACCESS_KEY
endpoint = https://${CF_ACCOUNT_ID}.r2.cloudflarestorage.com
acl = private
no_check_bucket = true
EOF
    touch /tmp/.rclone-configured
    echo "Rclone configured for bucket: $R2_BUCKET"
}

RCLONE_FLAGS="--transfers=16 --fast-list --s3-no-check-bucket"

# ============================================================
# RESTORE FROM R2
# ============================================================

if r2_configured; then
    setup_rclone

    echo "Checking R2 for existing backup..."
    # Check if R2 has an openclaw config backup
    if rclone ls "r2:${R2_BUCKET}/openclaw/openclaw.json" $RCLONE_FLAGS 2>/dev/null | grep -q openclaw.json; then
        echo "Restoring config from R2..."
        rclone copy "r2:${R2_BUCKET}/openclaw/" "$CONFIG_DIR/" $RCLONE_FLAGS -v 2>&1 || echo "WARNING: config restore failed with exit code $?"
        echo "Config restored"
    elif rclone ls "r2:${R2_BUCKET}/clawdbot/clawdbot.json" $RCLONE_FLAGS 2>/dev/null | grep -q clawdbot.json; then
        echo "Restoring from legacy R2 backup..."
        rclone copy "r2:${R2_BUCKET}/clawdbot/" "$CONFIG_DIR/" $RCLONE_FLAGS -v 2>&1 || echo "WARNING: legacy config restore failed with exit code $?"
        if [ -f "$CONFIG_DIR/clawdbot.json" ] && [ ! -f "$CONFIG_FILE" ]; then
            mv "$CONFIG_DIR/clawdbot.json" "$CONFIG_FILE"
        fi
        echo "Legacy config restored and migrated"
    else
        echo "No backup found in R2, starting fresh"
    fi

    # Restore workspace
    REMOTE_WS_COUNT=$(rclone ls "r2:${R2_BUCKET}/workspace/" $RCLONE_FLAGS 2>/dev/null | wc -l)
    if [ "$REMOTE_WS_COUNT" -gt 0 ]; then
        echo "Restoring workspace from R2 ($REMOTE_WS_COUNT files)..."
        mkdir -p "$WORKSPACE_DIR"
        rclone copy "r2:${R2_BUCKET}/workspace/" "$WORKSPACE_DIR/" $RCLONE_FLAGS -v 2>&1 || echo "WARNING: workspace restore failed with exit code $?"
        echo "Workspace restored"
    fi

    # Restore skills
    REMOTE_SK_COUNT=$(rclone ls "r2:${R2_BUCKET}/skills/" $RCLONE_FLAGS 2>/dev/null | wc -l)
    if [ "$REMOTE_SK_COUNT" -gt 0 ]; then
        echo "Restoring skills from R2 ($REMOTE_SK_COUNT files)..."
        mkdir -p "$SKILLS_DIR"
        rclone copy "r2:${R2_BUCKET}/skills/" "$SKILLS_DIR/" $RCLONE_FLAGS -v 2>&1 || echo "WARNING: skills restore failed with exit code $?"
        echo "Skills restored"
    fi
else
    echo "R2 not configured, starting fresh"
fi

# ============================================================
# ONBOARD (only if no config exists yet)
# ============================================================
if [ ! -f "$CONFIG_FILE" ]; then
    echo "No existing config found..."

    AUTH_ARGS=""
    if [ -n "$CLOUDFLARE_AI_GATEWAY_API_KEY" ] && [ -n "$CF_AI_GATEWAY_ACCOUNT_ID" ] && [ -n "$CF_AI_GATEWAY_GATEWAY_ID" ]; then
        AUTH_ARGS="--auth-choice cloudflare-ai-gateway-api-key \
            --cloudflare-ai-gateway-account-id $CF_AI_GATEWAY_ACCOUNT_ID \
            --cloudflare-ai-gateway-gateway-id $CF_AI_GATEWAY_GATEWAY_ID \
            --cloudflare-ai-gateway-api-key $CLOUDFLARE_AI_GATEWAY_API_KEY"
    elif [ -n "$ANTHROPIC_API_KEY" ]; then
        AUTH_ARGS="--auth-choice apiKey --anthropic-api-key $ANTHROPIC_API_KEY"
    elif [ -n "$OPENAI_API_KEY" ]; then
        AUTH_ARGS="--auth-choice openai-api-key --openai-api-key $OPENAI_API_KEY"
    fi

    if [ -n "$AUTH_ARGS" ]; then
        echo "Running openclaw onboard with direct provider key..."
        openclaw onboard --non-interactive --accept-risk \
            --mode local \
            $AUTH_ARGS \
            --gateway-port 18789 \
            --gateway-bind lan \
            --skip-channels \
            --skip-skills \
            --skip-health
        echo "Onboard completed"
    else
        # No direct provider key (e.g., using OpenRouter only).
        # Create minimal config — the patch step below will configure the provider.
        echo "No direct provider key — creating minimal config for OpenRouter..."
        echo '{}' > "$CONFIG_FILE"
        echo "Minimal config created"
    fi
else
    echo "Using existing config"
fi

# ============================================================
# PATCH CONFIG (channels, gateway auth, trusted proxies)
# ============================================================
# openclaw onboard handles provider/model config, but we need to patch in:
# - Channel config (Telegram, Discord, Slack)
# - Gateway token auth
# - Trusted proxies for sandbox networking
# - Base URL override for legacy AI Gateway path
node << 'EOFPATCH'
const fs = require('fs');

const configPath = '/root/.openclaw/openclaw.json';
console.log('Patching config at:', configPath);
let config = {};

try {
    config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
} catch (e) {
    console.log('Starting with empty config');
}

config.gateway = config.gateway || {};
config.channels = config.channels || {};

// Gateway configuration
config.gateway.port = 18789;
config.gateway.mode = 'local';
config.gateway.trustedProxies = ['10.1.0.0'];

if (process.env.OPENCLAW_GATEWAY_TOKEN) {
    config.gateway.auth = config.gateway.auth || {};
    config.gateway.auth.token = process.env.OPENCLAW_GATEWAY_TOKEN;
}

if (process.env.OPENCLAW_DEV_MODE === 'true') {
    config.gateway.controlUi = config.gateway.controlUi || {};
    config.gateway.controlUi.allowInsecureAuth = true;
}

// Legacy AI Gateway base URL override:
// ANTHROPIC_BASE_URL is picked up natively by the Anthropic SDK,
// so we don't need to patch the provider config. Writing a provider
// entry without a models array breaks OpenClaw's config validation.

// AI Gateway model override (CF_AI_GATEWAY_MODEL=provider/model-id)
// Adds a provider entry for any AI Gateway provider and sets it as default model.
// Examples:
//   workers-ai/@cf/meta/llama-3.3-70b-instruct-fp8-fast
//   openai/gpt-4o
//   anthropic/claude-sonnet-4-5
if (process.env.CF_AI_GATEWAY_MODEL) {
    const raw = process.env.CF_AI_GATEWAY_MODEL;
    const slashIdx = raw.indexOf('/');
    const gwProvider = raw.substring(0, slashIdx);
    const modelId = raw.substring(slashIdx + 1);

    const accountId = process.env.CF_AI_GATEWAY_ACCOUNT_ID;
    const gatewayId = process.env.CF_AI_GATEWAY_GATEWAY_ID;
    const apiKey = process.env.CLOUDFLARE_AI_GATEWAY_API_KEY;

    let baseUrl;
    if (accountId && gatewayId) {
        baseUrl = 'https://gateway.ai.cloudflare.com/v1/' + accountId + '/' + gatewayId + '/' + gwProvider;
        if (gwProvider === 'workers-ai') baseUrl += '/v1';
    } else if (gwProvider === 'workers-ai' && process.env.CF_ACCOUNT_ID) {
        baseUrl = 'https://api.cloudflare.com/client/v4/accounts/' + process.env.CF_ACCOUNT_ID + '/ai/v1';
    }

    if (baseUrl && apiKey) {
        const api = gwProvider === 'anthropic' ? 'anthropic-messages' : 'openai-completions';
        const providerName = 'cf-ai-gw-' + gwProvider;

        config.models = config.models || {};
        config.models.providers = config.models.providers || {};
        config.models.providers[providerName] = {
            baseUrl: baseUrl,
            apiKey: apiKey,
            api: api,
            models: [{ id: modelId, name: modelId, contextWindow: 131072, maxTokens: 8192 }],
        };
        config.agents = config.agents || {};
        config.agents.defaults = config.agents.defaults || {};
        config.agents.defaults.model = { primary: providerName + '/' + modelId };
        console.log('AI Gateway model override: provider=' + providerName + ' model=' + modelId + ' via ' + baseUrl);
    } else {
        console.warn('CF_AI_GATEWAY_MODEL set but missing required config (account ID, gateway ID, or API key)');
    }
}

// OpenRouter provider registration
// Registers OpenRouter as the sole provider. When OpenRouter is active,
// direct Anthropic/OpenAI providers are removed to prevent bypassing.
// The default model is set via DEFAULT_MODEL env var (configurable from
// dashboard/wrangler.jsonc) — no hardcoded model selection.
if (process.env.OPENROUTER_API_KEY) {
    config.models = config.models || {};
    config.models.providers = config.models.providers || {};

    // Remove direct providers — all calls go through OpenRouter
    delete config.models.providers.anthropic;
    delete config.models.providers.openai;

    config.models.providers.openrouter = {
        baseUrl: 'https://openrouter.ai/api/v1',
        apiKey: process.env.OPENROUTER_API_KEY,
        api: 'openai-completions',
        models: [
            // --- FREE TIER ---
            { id: 'openrouter/free', name: 'auto-free', contextWindow: 200000, maxTokens: 8192 },
            { id: 'openrouter/pony-alpha', name: 'pony-alpha', contextWindow: 200000, maxTokens: 131000 },
            { id: 'google/gemini-2.5-flash:free', name: 'gemini-2.5-flash-free', contextWindow: 1000000, maxTokens: 8192 },
            { id: 'google/gemini-3-flash-preview:free', name: 'gemini-3-flash-free', contextWindow: 1000000, maxTokens: 8192 },
            { id: 'meta-llama/llama-3.3-70b-instruct:free', name: 'llama-3.3-70b-free', contextWindow: 131000, maxTokens: 8192 },
            { id: 'meta-llama/llama-3.1-405b:free', name: 'llama-3.1-405b-free', contextWindow: 131000, maxTokens: 8192 },
            { id: 'deepseek/deepseek-r1-0528:free', name: 'deepseek-r1-free', contextWindow: 164000, maxTokens: 8192 },
            { id: 'openai/gpt-oss-120b:free', name: 'gpt-oss-120b-free', contextWindow: 131000, maxTokens: 8192 },
            { id: 'xiaomi/mimo-v2-flash:free', name: 'mimo-v2-flash-free', contextWindow: 262000, maxTokens: 8192 },
            { id: 'mistralai/devstral-2512:free', name: 'devstral-2-free', contextWindow: 262000, maxTokens: 8192 },
            { id: 'qwen/qwen3-coder:free', name: 'qwen3-coder-free', contextWindow: 262000, maxTokens: 8192 },
            { id: 'nvidia/nemotron-3-nano-30b-a3b:free', name: 'nemotron-3-nano-free', contextWindow: 256000, maxTokens: 8192 },
            // --- ULTRA-CHEAP ($) ---
            { id: 'mistralai/devstral-2512', name: 'devstral-2', contextWindow: 262000, maxTokens: 8192 },
            { id: 'qwen/qwen3-30b-a3b', name: 'qwen3-30b', contextWindow: 262000, maxTokens: 8192 },
            { id: 'z-ai/glm-4.7-flash', name: 'glm-4.7-flash', contextWindow: 202000, maxTokens: 8192 },
            { id: 'qwen/qwen3-coder-next', name: 'qwen3-coder-next', contextWindow: 262000, maxTokens: 8192 },
            { id: 'bytedance-seed/seed-1.6-flash', name: 'seed-1.6-flash', contextWindow: 262000, maxTokens: 8192 },
            { id: 'xiaomi/mimo-v2-flash', name: 'mimo-v2-flash', contextWindow: 262000, maxTokens: 8192 },
            { id: 'qwen/qwq-32b', name: 'qwq-32b', contextWindow: 65000, maxTokens: 8192 },
            { id: 'deepseek/deepseek-v3.2', name: 'deepseek-v3.2', contextWindow: 164000, maxTokens: 8192 },
            { id: 'deepseek/deepseek-v3.2-speciale', name: 'deepseek-v3.2-speciale', contextWindow: 164000, maxTokens: 8192 },
            { id: 'x-ai/grok-4.1-fast', name: 'grok-4.1-fast', contextWindow: 2000000, maxTokens: 8192 },
            { id: 'qwen/qwen3-235b-a22b', name: 'qwen3-235b', contextWindow: 262000, maxTokens: 8192 },
            { id: 'z-ai/glm-4.7', name: 'glm-4.7', contextWindow: 202000, maxTokens: 8192 },
            { id: 'minimax/minimax-m2.1', name: 'minimax-m2.1', contextWindow: 196000, maxTokens: 8192 },
            // --- MID-RANGE ($$) ---
            { id: 'google/gemini-3-flash-preview', name: 'gemini-3-flash', contextWindow: 1000000, maxTokens: 8192 },
            { id: 'mistralai/mistral-large-2512', name: 'mistral-large-3', contextWindow: 262000, maxTokens: 8192 },
            { id: 'moonshotai/kimi-k2.5', name: 'kimi-k2.5', contextWindow: 262000, maxTokens: 8192 },
            { id: 'deepseek/deepseek-r1', name: 'deepseek-r1', contextWindow: 64000, maxTokens: 8192 },
            { id: 'z-ai/glm-5', name: 'glm-5', contextWindow: 202000, maxTokens: 8192 },
            { id: 'anthropic/claude-haiku-4.5', name: 'claude-haiku-4.5', contextWindow: 1000000, maxTokens: 8192 },
            { id: 'qwen/qwen3-max-thinking', name: 'qwen3-max-thinking', contextWindow: 262000, maxTokens: 8192 },
            { id: 'openai/gpt-5.1', name: 'gpt-5.1', contextWindow: 400000, maxTokens: 8192 },
            { id: 'openai/gpt-5.2', name: 'gpt-5.2', contextWindow: 400000, maxTokens: 8192 },
            { id: 'google/gemini-3-pro-preview', name: 'gemini-3-pro', contextWindow: 1000000, maxTokens: 8192 },
            // --- PREMIUM ($$$) ---
            { id: 'openai/gpt-5.3-codex', name: 'gpt-5.3-codex', contextWindow: 256000, maxTokens: 8192 },
            { id: 'anthropic/claude-sonnet-4.5', name: 'claude-sonnet-4.5', contextWindow: 200000, maxTokens: 8192 },
            { id: 'anthropic/claude-opus-4.5', name: 'claude-opus-4.5', contextWindow: 200000, maxTokens: 8192 },
            { id: 'anthropic/claude-opus-4.6', name: 'claude-opus-4.6', contextWindow: 1000000, maxTokens: 8192 },
            { id: 'openai/gpt-5.2-pro', name: 'gpt-5.2-pro', contextWindow: 400000, maxTokens: 8192 }
        ]
    };

    // Default model: configurable via env var, falls back to Haiku
    const defaultModel = process.env.DEFAULT_MODEL || 'openrouter/deepseek/deepseek-v3.2';
    config.agents = config.agents || {};
    config.agents.defaults = config.agents.defaults || {};
    config.agents.defaults.model = { primary: defaultModel };
    console.log('OpenRouter: sole provider. Default model: ' + defaultModel + ' (change via DEFAULT_MODEL env var or dashboard)');
}

// Telegram configuration
// Overwrite entire channel object to drop stale keys from old R2 backups
// that would fail OpenClaw's strict config validation (see #47)
if (process.env.TELEGRAM_BOT_TOKEN) {
    const dmPolicy = process.env.TELEGRAM_DM_POLICY || 'pairing';
    config.channels.telegram = {
        botToken: process.env.TELEGRAM_BOT_TOKEN,
        enabled: true,
        dmPolicy: dmPolicy,
    };
    if (process.env.TELEGRAM_DM_ALLOW_FROM) {
        config.channels.telegram.allowFrom = process.env.TELEGRAM_DM_ALLOW_FROM.split(',');
    } else if (dmPolicy === 'open') {
        config.channels.telegram.allowFrom = ['*'];
    }
}

// Discord configuration
// Discord uses a nested dm object: dm.policy, dm.allowFrom (per DiscordDmConfig)
if (process.env.DISCORD_BOT_TOKEN) {
    const dmPolicy = process.env.DISCORD_DM_POLICY || 'pairing';
    const dm = { policy: dmPolicy };
    if (dmPolicy === 'open') {
        dm.allowFrom = ['*'];
    }
    config.channels.discord = {
        token: process.env.DISCORD_BOT_TOKEN,
        enabled: true,
        dm: dm,
    };
}

// Slack configuration
if (process.env.SLACK_BOT_TOKEN && process.env.SLACK_APP_TOKEN) {
    config.channels.slack = {
        botToken: process.env.SLACK_BOT_TOKEN,
        appToken: process.env.SLACK_APP_TOKEN,
        enabled: true,
    };
}

fs.writeFileSync(configPath, JSON.stringify(config, null, 2));
console.log('Configuration patched successfully');
EOFPATCH

# ============================================================
# BACKGROUND SYNC LOOP
# ============================================================
if r2_configured; then
    echo "Starting background R2 sync loop..."
    (
        MARKER=/tmp/.last-sync-marker
        LOGFILE=/tmp/r2-sync.log
        touch "$MARKER"

        while true; do
            sleep 30

            CHANGED=/tmp/.changed-files
            {
                find "$CONFIG_DIR" -newer "$MARKER" -type f -printf '%P\n' 2>/dev/null
                find "$WORKSPACE_DIR" -newer "$MARKER" \
                    -not -path '*/node_modules/*' \
                    -not -path '*/.git/*' \
                    -type f -printf '%P\n' 2>/dev/null
            } > "$CHANGED"

            COUNT=$(wc -l < "$CHANGED" 2>/dev/null || echo 0)

            if [ "$COUNT" -gt 0 ]; then
                echo "[sync] Uploading changes ($COUNT files) at $(date)" >> "$LOGFILE"
                rclone sync "$CONFIG_DIR/" "r2:${R2_BUCKET}/openclaw/" \
                    $RCLONE_FLAGS --exclude='*.lock' --exclude='*.log' --exclude='*.tmp' --exclude='.git/**' 2>> "$LOGFILE"
                if [ -d "$WORKSPACE_DIR" ]; then
                    rclone sync "$WORKSPACE_DIR/" "r2:${R2_BUCKET}/workspace/" \
                        $RCLONE_FLAGS --exclude='skills/**' --exclude='.git/**' --exclude='node_modules/**' 2>> "$LOGFILE"
                fi
                if [ -d "$SKILLS_DIR" ]; then
                    rclone sync "$SKILLS_DIR/" "r2:${R2_BUCKET}/skills/" \
                        $RCLONE_FLAGS 2>> "$LOGFILE"
                fi
                date -Iseconds > "$LAST_SYNC_FILE"
                touch "$MARKER"
                echo "[sync] Complete at $(date)" >> "$LOGFILE"
            fi
        done
    ) &
    echo "Background sync loop started (PID: $!)"
fi

# ============================================================
# START GATEWAY
# ============================================================
echo "Starting OpenClaw Gateway..."
echo "Gateway will be available on port 18789"

rm -f /tmp/openclaw-gateway.lock 2>/dev/null || true
rm -f "$CONFIG_DIR/gateway.lock" 2>/dev/null || true

echo "Dev mode: ${OPENCLAW_DEV_MODE:-false}"

if [ -n "$OPENCLAW_GATEWAY_TOKEN" ]; then
    echo "Starting gateway with token auth..."
    exec openclaw gateway --port 18789 --verbose --allow-unconfigured --bind lan --token "$OPENCLAW_GATEWAY_TOKEN"
else
    echo "Starting gateway with device pairing (no token)..."
    exec openclaw gateway --port 18789 --verbose --allow-unconfigured --bind lan
fi
