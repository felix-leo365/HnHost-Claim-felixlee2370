#!/bin/bash

# ===== 个人配置（通过 GitHub Secrets 注入）=====
: "${HNHOST_ACCOUNT:?请设置 GitHub Secret: HNHOST_ACCOUNT}"

# HNHOST_ACCOUNT 格式（多账号换行分隔）:
# 昵称1,Discord Token1
# 昵称2,Discord Token2

# ===== 公共配置 =====
SITE_URL="https://client.hnhost.net"
DISCORD_API="https://discord.com/api/v9"
CLIENT_ID="977981235618021377"
REDIRECT_URI="https://client.hnhost.net/backend/pdo/discord.php"
REDIRECT_URI_ENCODED="https%3A%2F%2Fclient.hnhost.net%2Fbackend%2Fpdo%2Fdiscord.php"
SCOPE="identify%20email%20guilds%20guilds.join"
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36"

# ===== 代理配置 =====
if [ -n "$GOST_PROXY" ]; then
  PROXY="-x http://127.0.0.1:8080"
  echo "🛡️ 使用代理模式"
else
  PROXY=""
  echo "🌐 直连模式"
fi

# ===== TG 推送函数 =====
tg_notify() {
  local nickname="$1"
  local coin_result="$2"
  local expire_date="$3"
  if [ -n "$TG_BOT" ]; then
    local TG_CHAT_ID TG_TOKEN RUN_TIME MESSAGE
    TG_CHAT_ID=$(echo "$TG_BOT" | cut -d',' -f1)
    TG_TOKEN=$(echo "$TG_BOT" | cut -d',' -f2)
    RUN_TIME=$(date '+%Y-%m-%d %H:%M:%S')
    MESSAGE="🎮 HnHost HN\$领取通知
🕐 运行时间: ${RUN_TIME}
🖥️ 服务器: ${nickname}
💰 最新HN\$: ${coin_result}
📅 利用期限: ${expire_date}"
    curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
      -d chat_id="${TG_CHAT_ID}" \
      -d text="${MESSAGE}" > /dev/null
    echo "📨 TG 推送成功"
  fi
}

# ===== 单账号处理函数 =====
process_account() {
  local HN_NICKNAME="$1"
  local HN_DISCORD_TOKEN="$2"
  local RESULT COIN_RESULT EXPIRE_DATE COINS

  echo "🕐 运行时间: $(date '+%Y-%m-%d %H:%M:%S')"
  echo "🖥️ 账号昵称: ${HN_NICKNAME}"
  echo ""

  # ===== Step 1: Discord OAuth 授权，获取 code =====
  echo "🔑 Step 1: Discord OAuth 授权..."

  local OAUTH_RESPONSE OAUTH_CODE OAUTH_BODY
  OAUTH_RESPONSE=$(curl -s -w "\n%{http_code}" $PROXY \
    -X POST "${DISCORD_API}/oauth2/authorize?client_id=${CLIENT_ID}&response_type=code&redirect_uri=${REDIRECT_URI_ENCODED}&scope=${SCOPE}" \
    -H "accept: */*" \
    -H "accept-language: zh-CN,zh;q=0.9" \
    -H "authorization: ${HN_DISCORD_TOKEN}" \
    -H "content-type: application/json" \
    -H "origin: https://discord.com" \
    -H "referer: https://discord.com/oauth2/authorize?client_id=${CLIENT_ID}&redirect_uri=${REDIRECT_URI_ENCODED}&response_type=code&scope=identify+email+guilds+guilds.join" \
    -H "user-agent: ${UA}" \
    -d "{\"permissions\":\"0\",\"authorize\":true,\"integration_type\":0,\"location_context\":{\"guild_id\":\"10000\",\"channel_id\":\"10000\",\"channel_type\":10000}}")

  OAUTH_CODE=$(echo "$OAUTH_RESPONSE" | tail -n1)
  OAUTH_BODY=$(echo "$OAUTH_RESPONSE" | head -n-1)
  echo "   Discord OAuth 响应码: ${OAUTH_CODE}"

  if [ "$OAUTH_CODE" != "200" ]; then
    echo "❌ Discord OAuth 授权失败！状态码: ${OAUTH_CODE}"
    case "$OAUTH_CODE" in
      401) RESULT="❌ 失败！Discord Token 无效或已过期" ;;
      403) RESULT="❌ 失败！Discord Token 权限不足" ;;
      429) RESULT="❌ 失败！Discord API 频率限制（rate limit）" ;;
      *)   RESULT="❌ 失败！Discord OAuth 响应码: ${OAUTH_CODE}" ;;
    esac
    tg_notify "$HN_NICKNAME" "$RESULT" "➖ 未获取"
    return 1
  fi

  local REDIRECT_LOCATION AUTH_CODE
  REDIRECT_LOCATION=$(echo "$OAUTH_BODY" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('location', ''))
" 2>/dev/null)

  if [ -z "$REDIRECT_LOCATION" ]; then
    echo "❌ 无法从 OAuth 响应中提取 redirect location"
    tg_notify "$HN_NICKNAME" "❌ 失败！无法提取 OAuth redirect location" "➖ 未获取"
    return 1
  fi

  AUTH_CODE=$(echo "$REDIRECT_LOCATION" | grep -oP '(?<=code=)[^&]+')
  if [ -z "$AUTH_CODE" ]; then
    echo "❌ 无法从 redirect URL 提取 code"
    tg_notify "$HN_NICKNAME" "❌ 失败！无法提取 OAuth code" "➖ 未获取"
    return 1
  fi

  echo "✅ 获取 OAuth code 成功！"
  echo "   code: ${AUTH_CODE:0:10}...(已截断)"

  # ===== Step 2: 用 code 换取 PHPSESSID =====
  echo ""
  echo "🔄 Step 2: 用 code 换取 Session..."

  local COOKIEJAR PHPSESSID COOKIE SESSION_RESPONSE
  COOKIEJAR=$(mktemp)

  SESSION_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" $PROXY \
    -c "$COOKIEJAR" \
    --max-redirs 5 \
    -L \
    -X GET "${REDIRECT_URI}?code=${AUTH_CODE}" \
    -H "accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7" \
    -H "accept-language: zh-CN,zh;q=0.9" \
    -H "user-agent: ${UA}")

  echo "   Session 响应码: ${SESSION_RESPONSE}"
  PHPSESSID=$(grep -oP '(?<=\tPHPSESSID\t)\S+' "$COOKIEJAR" | tail -1)
  rm -f "$COOKIEJAR"

  if [ -z "$PHPSESSID" ]; then
    echo "❌ 无法获取 PHPSESSID"
    tg_notify "$HN_NICKNAME" "❌ 失败！无法获取 PHPSESSID" "➖ 未获取"
    return 1
  fi

  echo "✅ 获取 PHPSESSID 成功！"
  echo "   PHPSESSID: ${PHPSESSID:0:8}...(已截断)"
  COOKIE="PHPSESSID=${PHPSESSID}"

  # ===== Step 3: 触发签到 =====
  echo ""
  echo "🪙 Step 3: 触发签到..."

  local TRIGGER_RESPONSE
  TRIGGER_RESPONSE=$(curl -s -o /dev/null -w "%{http_code}" $PROXY \
    --max-redirs 0 \
    -X GET "${SITE_URL}/index.php?generalEvent=dailyReward" \
    -H "accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7" \
    -H "accept-language: zh-CN,zh;q=0.9" \
    -H "referer: ${SITE_URL}/index.php" \
    -H "sec-fetch-dest: document" \
    -H "sec-fetch-mode: navigate" \
    -H "sec-fetch-site: same-origin" \
    -H "upgrade-insecure-requests: 1" \
    -H "user-agent: ${UA}" \
    -H "cookie: ${COOKIE}")

  echo "   触发响应码: ${TRIGGER_RESPONSE}"

  if [ "$TRIGGER_RESPONSE" != "302" ]; then
    echo "❌ 触发签到失败！预期 302，实际: ${TRIGGER_RESPONSE}"
    case "$TRIGGER_RESPONSE" in
      403) RESULT="❌ 失败！Session 无效或 Cloudflare 拦截" ;;
      200) RESULT="❌ 失败！未触发跳转，可能今日已签到或 Session 失效" ;;
      *)   RESULT="❌ 失败！触发响应码: ${TRIGGER_RESPONSE}" ;;
    esac
    tg_notify "$HN_NICKNAME" "$RESULT" "➖ 未获取"
    return 1
  fi

  echo "✅ 触发成功（302 跳转）"

  # ===== Step 4: 确认签到 =====
  echo ""
  echo "✅ Step 4: 确认签到..."

  local CONFIRM_RESPONSE CONFIRM_CODE CONFIRM_BODY
  CONFIRM_RESPONSE=$(curl -s -w "\n%{http_code}" $PROXY \
    -X GET "${SITE_URL}/index.php?dailyReward=OK" \
    -H "accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7" \
    -H "accept-language: zh-CN,zh;q=0.9" \
    -H "referer: ${SITE_URL}/index.php" \
    -H "sec-fetch-dest: document" \
    -H "sec-fetch-mode: navigate" \
    -H "sec-fetch-site: same-origin" \
    -H "upgrade-insecure-requests: 1" \
    -H "user-agent: ${UA}" \
    -H "cookie: ${COOKIE}")

  CONFIRM_CODE=$(echo "$CONFIRM_RESPONSE" | tail -n1)
  CONFIRM_BODY=$(echo "$CONFIRM_RESPONSE" | head -n-1)
  echo "   确认响应码: ${CONFIRM_CODE}"

  if [ "$CONFIRM_CODE" != "200" ]; then
    echo "❌ 确认签到失败！状态码: ${CONFIRM_CODE}"
    tg_notify "$HN_NICKNAME" "❌ 失败！确认步骤响应码: ${CONFIRM_CODE}" "➖ 未获取"
    return 1
  fi

  # ===== Step 5: 解析签到结果 =====
  echo ""
  echo "🔍 Step 5: 解析签到结果..."

  EXPIRE_DATE=$(echo "$CONFIRM_BODY" | grep -oP '(?<=class="text-secondary text-xs font-weight-bold">)\d{4}/\d{2}/\d{2}' | head -1)
  [ -z "$EXPIRE_DATE" ] && EXPIRE_DATE="➖ 未获取"
  echo "   到期日: ${EXPIRE_DATE}"

  local USER_ID COINS_RESP
  USER_ID=$(echo "$CONFIRM_BODY" | grep -oP "(?<=fx=userInfo&userId=)[a-z0-9]+" | head -1)

  if [ -n "$USER_ID" ]; then
    COINS_RESP=$(curl -s $PROXY \
      "${SITE_URL}/middleware/localApi/homeInfoApi.php?fx=userInfo&userId=${USER_ID}" \
      -H "cookie: ${COOKIE}" \
      -H "user-agent: ${UA}")
    COINS=$(echo "$COINS_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['response'].get('hncoin',''))" 2>/dev/null)
  fi

  if echo "$CONFIRM_BODY" | grep -qE "领取奖励成功|領取獎勵成功|alert-success"; then
    echo "✅ 签到成功，已领取每日奖励！"
    echo "💰 当前 HN Points: HN\$ ${COINS}"
    COIN_RESULT="✅ 领取成功 ${COINS},00"
    RESULT="✅ 签到成功"

  elif echo "$CONFIRM_BODY" | grep -qE "已领取每日奖励|已領取每日獎勵|btn-outline-danger"; then
    echo "⏭️  今日已签到过，跳过"
    COIN_RESULT="⌛️ 期限未至 ${COINS},00"
    RESULT="⏭️ 今日已签到"

  else
    echo "⚠️  响应 200 但无法识别签到结果"
    echo "   响应片段: $(echo "$CONFIRM_BODY" | grep -i 'reward\|奖励\|金币\|coin\|alert' | head -3)"
    COIN_RESULT="⚠️ 响应异常"
    RESULT="⚠️ 响应异常，请人工检查"
  fi

  # ===== Step 6: 检查是否需要续期（距到期 < 3 天）=====
  echo ""
  echo "📅 Step 6: 检查续期条件..."

  if [ "$EXPIRE_DATE" != "➖ 未获取" ]; then
    local EXPIRE_TS NOW_TS DIFF_DAYS
    EXPIRE_TS=$(date -d "$(echo "$EXPIRE_DATE" | tr '/' '-')" '+%s' 2>/dev/null)
    NOW_TS=$(date '+%s')
    DIFF_DAYS=$(( (EXPIRE_TS - NOW_TS) / 86400 ))
    echo "   距到期还有: ${DIFF_DAYS} 天"

    if [ "$DIFF_DAYS" -lt 3 ]; then
      echo "⚠️  距到期不足 3 天，执行续期..."

      local SERVER_RENEW_ID
      SERVER_RENEW_ID=$(echo "$CONFIRM_BODY" | grep -oP '(?<=server=renew&id=)[a-z0-9]+' | head -1)

      if [ -z "$SERVER_RENEW_ID" ]; then
        echo "❌ 无法提取服务器 ID，跳过续期"
      else
        echo "   服务器 ID: ${SERVER_RENEW_ID}"
        local RENEW_CODE
        RENEW_CODE=$(curl -s -o /dev/null -w "%{http_code}" $PROXY \
          -X GET "${SITE_URL}/index.php?server=renew&id=${SERVER_RENEW_ID}" \
          -H "accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7" \
          -H "accept-language: zh-CN,zh;q=0.9" \
          -H "referer: ${SITE_URL}/index.php" \
          -H "sec-fetch-dest: document" \
          -H "sec-fetch-mode: navigate" \
          -H "sec-fetch-site: same-origin" \
          -H "upgrade-insecure-requests: 1" \
          -H "user-agent: ${UA}" \
          -H "cookie: ${COOKIE}")

        echo "   续期响应码: ${RENEW_CODE}"

        if [ "$RENEW_CODE" = "200" ] || [ "$RENEW_CODE" = "302" ]; then
          echo "✅ 续期成功！正在刷新到期日..."
          local REFRESH_BODY NEW_EXPIRE
          REFRESH_BODY=$(curl -s $PROXY \
            -X GET "${SITE_URL}/index.php" \
            -H "accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7" \
            -H "accept-language: zh-CN,zh;q=0.9" \
            -H "user-agent: ${UA}" \
            -H "cookie: ${COOKIE}")
          NEW_EXPIRE=$(echo "$REFRESH_BODY" | grep -oP '(?<=class="text-secondary text-xs font-weight-bold">)\d{4}/\d{2}/\d{2}' | head -1)
          if [ -n "$NEW_EXPIRE" ]; then
            EXPIRE_DATE="$NEW_EXPIRE"
            echo "   新到期日: ${EXPIRE_DATE}"
          fi
        else
          echo "❌ 续期失败！响应码: ${RENEW_CODE}"
        fi
      fi
    else
      echo "✅ 距到期还有 ${DIFF_DAYS} 天，无需续期"
    fi
  else
    echo "⚠️  无法获取到期日，跳过续期检查"
  fi

  # ===== TG 推送 =====
  tg_notify "$HN_NICKNAME" "$COIN_RESULT" "$EXPIRE_DATE"

  echo "========================================"
  if [[ "$RESULT" == ✅* ]] || [[ "$RESULT" == ⏭️* ]]; then
    echo "🎉 任务完成！"
    return 0
  else
    echo "💀 任务失败！"
    return 1
  fi
}

# ===== 主流程：遍历所有账号 =====
echo "========================================"
echo "🔧 HNHost 每日签到任务（多账号模式）"
echo "🕐 运行时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "========================================"

ACCOUNT_INDEX=0
FINAL_EXIT=0

while IFS= read -r LINE || [ -n "$LINE" ]; do
  [ -z "$LINE" ] && continue

  ACCOUNT_INDEX=$((ACCOUNT_INDEX + 1))
  ACCT_NICKNAME=$(echo "$LINE" | cut -d',' -f1)
  ACCT_TOKEN=$(echo "$LINE" | cut -d',' -f2-)

  echo ""
  echo "========================================"
  echo "👤 账号 ${ACCOUNT_INDEX}: ${ACCT_NICKNAME}"
  echo "========================================"

  process_account "$ACCT_NICKNAME" "$ACCT_TOKEN"
  EXIT_CODE=$?
  [ $EXIT_CODE -ne 0 ] && FINAL_EXIT=$EXIT_CODE

  sleep 3

done <<< "$HNHOST_ACCOUNT"

echo ""
echo "========================================"
echo "🏁 所有账号处理完毕"
echo "========================================"
exit $FINAL_EXIT
