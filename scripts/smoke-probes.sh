# scripts/smoke.sh source 本文件，不单独执行。
# shellcheck shell=bash
# Penpot 的登录链不能只靠重定向走完：授权起点是 POST 接口（返回 JSON），首次登录停在官方
# 姓名确认表单。探测按浏览器会发的请求自己走一遍（发起 → 跟跳转 → 调官方 register-profile），
# 不写库、不预建账号、不改应用；断言当前用户是网关注入邮箱对应的 OIDC 主人。
web_assert() { grep -qi 'Full-stack design'; }

penpot_identity_check() {
  local jar="$1" url="$2" owner_email="$3" start final token profile
  start="$(curl -fsS --noproxy '*' --max-time 30 -b "$jar" -c "$jar" \
    -H 'Accept: application/json' -X POST "$url/api/auth/oidc?provider=oidc")" || return 1
  start="$(jq -er '.redirectUri // .["redirect-uri"]' <<<"$start")" || return 1
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

marker_file() { # SMOKE_STATE 在套件里是状态目录（e2e 传的是标记文件本身），标记放对应路径
  if [[ -d "$SMOKE_STATE" ]]; then printf '%s' "$SMOKE_STATE/penpot-marker"; else printf '%s' "${SMOKE_STATE}.marker"; fi
}

penpot_rpc() { # <命令> <JSON 参数>：带应用会话（identity_check 建立的）调 Penpot RPC
  curl -sS --noproxy '*' --fail-with-body -b "$SMOKE_JAR" -H 'Content-Type: application/json' \
    -d "$2" "$SMOKE_WEB_URL/api/rpc/command/$1"
}

# 数据：设计文件就是用户数据（Postgres 在插件数据目录，重装保留）。data_write 调应用自己的 RPC：
# 建一个名字带随机标记的项目（create-project，挂在自己的默认 team 下），data_check 重装/升级后项目还在。
data_write() {
  local teams team_id marker resp
  teams="$(penpot_rpc get-teams '{}')" || { echo "get-teams 失败：$teams"; return 1; }
  team_id="$(jq -r 'if type == "array" then (.[0].id // empty) else (.data[0].id // empty) end' <<<"$teams")"
  [[ -n "$team_id" ]] || { echo "拿不到 team：$(head -c 300 <<<"$teams")"; return 1; }
  marker="wonton-smoke-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
  resp="$(penpot_rpc create-project "{\"teamId\":\"$team_id\",\"name\":\"$marker\"}")" ||
    { echo "create-project 失败：$resp"; return 1; }
  jq -e --arg m "$marker" '.name == $m and (.id != null)' <<<"$resp" >/dev/null ||
    { echo "项目没建成：$(head -c 300 <<<"$resp")"; return 1; }
  jq -nc --arg p "$(jq -r '.id' <<<"$resp")" --arg t "$team_id" --arg m "$marker" \
    '{project_id:$p,team_id:$t,name:$m}' >"$(marker_file)"
}

data_check() {
  local marker_projects project_id team_id name
  read -r project_id team_id name < <(jq -r '[.project_id, .team_id, .name] | @tsv' "$(marker_file)" 2>/dev/null) || true
  [[ -n "$project_id" && -n "$team_id" ]] || { echo "没有 data_write 留下的标记"; return 1; }
  marker_projects="$(penpot_rpc get-projects "{\"teamId\":\"$team_id\"}")" ||
    { echo "get-projects 失败：$marker_projects"; return 1; }
  jq -e --arg p "$project_id" --arg m "$name" 'any(.[]; .id == $p and .name == $m)' <<<"$marker_projects" >/dev/null ||
    { echo "升级/重装后找不到项目 $name（$project_id）：$(head -c 300 <<<"$marker_projects")"; return 1; }
}
