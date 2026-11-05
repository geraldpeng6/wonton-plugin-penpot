# Penpot 的登录链不能只靠重定向走完：授权起点是 POST 接口（返回 JSON），首次登录停在官方
# 姓名确认表单。探测按浏览器会发的请求自己走一遍（发起 → 跟跳转 → 调官方 register-profile），
# 不写库、不预建账号、不改应用；断言当前用户是网关注入邮箱对应的 OIDC 主人。
web_assert() { grep -qi 'Full-stack design'; }

penpot_identity_check() {
  local jar="$1" url="$2" owner_email="$3" start final token profile
  start="$(curl -fsS --noproxy '*' --max-time 30 -b "$jar" -c "$jar" \
    -H 'Accept: application/json' -X POST "$url/api/auth/oidc?provider=oidc")" || return 1
  start="$(jq -er '.redirectUri // .redirect-uri' <<<"$start")" || return 1
  final="$(curl -fsS --noproxy '*' --max-time 60 -L -b "$jar" -c "$jar" \
    -H 'Accept: text/html' -o /dev/null -w '%{url_effective}' "$start")" || return 1
  token="$(python3 -c 'import sys,urllib.parse
f=urllib.parse.urlsplit(sys.argv[1]).fragment
q=f.split("?",1)[1] if "?" in f else ""
print(urllib.parse.parse_qs(q).get("token",[""])[0])' "$final")" || return 1
  [[ -n "$token" ]] || { echo "OIDC 回跳没带注册令牌：$final"; return 1; }
  # 官方注册表单提交的就是这一个 RPC；register-profile 会建立应用会话。
  profile="$(curl -fsS --noproxy '*' --max-time 30 -b "$jar" -c "$jar" \
    -H 'Accept: application/json' -H 'Content-Type: application/json' \
    -d "{\"token\":\"$token\"}" "$url/api/rpc/command/register-profile")" || return 1
  profile="$(curl -fsS --noproxy '*' --max-time 30 -b "$jar" \
    -H 'Accept: application/json' "$url/api/rpc/command/get-profile")" || return 1
  jq -e --arg email "$owner_email" '
    .id != null and .id != "00000000-0000-0000-0000-000000000000" and
    .authBackend == "oidc" and .isActive == true and .email == $email
  ' <<<"$profile" >/dev/null || {
    echo "应用当前用户不是 OIDC 主人（$owner_email）：$(head -c 200 <<<"$profile")"
    return 1
  }
}

identity_check() {
  local email
  email="$(smoke_api GET /_wonton/api/owner-profile | jq -er '.email')" || return 1
  penpot_identity_check "$SMOKE_JAR" "$SMOKE_WEB_URL" "$email"
}
