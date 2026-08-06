# GitHub 仓库改名与历史归档迁移手册

> 本手册只描述维护窗口的执行方法。本 PR 不调用 GitHub 或 App Store Connect，也不执行仓库删除、改名、发布或部署。

## 目标

将 `gaixianggeng/mimi-remote` 作为唯一完整源码与 Release 仓库，同时处理现有历史 `gaixianggeng/mimi-remote` 归档仓库与当前完整源码仓库的名称冲突。

用户已经明确授权删除现有历史 `gaixianggeng/mimi-remote` 仓库。删除动作不可恢复，因此先把历史 tags、Releases、附件和 checksum 离线备份，再在维护窗口内完成删除、改名和外部链接核对。

本 PR 只更新仓库内的 canonical 链接、发布门禁和文档，不执行任何外部删除或改名。

## 方案

维护者必须安排一个可观察、可停止的短维护窗口，按两个阶段执行：

1. **窗口前备份与核对**：备份旧归档仓库 `gaixianggeng/mimi-remote` 的 Git refs，以及 `v0.1.0` 至 `v0.2.2` 的 tags、Releases、全部附件和 checksum；第二人复核清单后才允许进入窗口。
2. **窗口内切换身份**：确认本 PR 已合并且检查全绿后，删除旧归档仓库；立即把当前 `gaixianggeng/codex-ipad-agent` 改名为 `mimi-remote`；更新本地 `origin`，再逐项校验重定向、新 clone、Release、Actions、Homebrew 和 App Store 元数据。

两个阶段都必须在确认点停下来。任何备份缺项、权限不明、Release 资产不完整或改名 API 失败，都应停止，不要继续发布新资产。

## 实现

### 阶段一：维护窗口前备份与核对

以下命令只读 GitHub 并写入指定的离线备份目录；不要把 Token、私有配置或工作树凭据放入备份。执行前确认 `gh auth status` 使用的是仓库维护者账号，并把 `BACKUP_ROOT` 指向加密磁盘或受控离线介质。

```bash
set -euo pipefail

OLD_ARCHIVE_REPO="gaixianggeng/mimi-remote"
BACKUP_ROOT="/secure/offline/mimi-remote-history-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_ROOT/releases"
gh auth status

# 备份历史仓库完整 refs，并生成可独立校验的 bundle。
gh repo clone "$OLD_ARCHIVE_REPO" "$BACKUP_ROOT/repository"
git -C "$BACKUP_ROOT/repository" fetch --tags --force --prune
git -C "$BACKUP_ROOT/repository" bundle create "$BACKUP_ROOT/mimi-remote-history.bundle" --all
git -C "$BACKUP_ROOT/repository" tag --list --sort=version:refname

# 逐一核对历史仓库的全部已知 tag 和 Release。
expected_tags=(v0.1.0 v0.1.1 v0.1.2 v0.1.3 v0.1.4 v0.2.0 v0.2.1 v0.2.2)
printf '%s\n' "${expected_tags[@]}" > "$BACKUP_ROOT/expected-tags.txt"
gh release list --repo "$OLD_ARCHIVE_REPO" --limit 100 \
  --json tagName --jq '.[].tagName' | LC_ALL=C sort > "$BACKUP_ROOT/actual-release-tags.txt"
diff -u \
  <(LC_ALL=C sort "$BACKUP_ROOT/expected-tags.txt") \
  "$BACKUP_ROOT/actual-release-tags.txt"

for tag in "${expected_tags[@]}"; do
  git -C "$BACKUP_ROOT/repository" show-ref --tags --verify "refs/tags/$tag"
  mkdir -p "$BACKUP_ROOT/releases/$tag"
  gh release view "$tag" --repo "$OLD_ARCHIVE_REPO" \
    --json name,tagName,targetCommitish,body,isDraft,isPrerelease,createdAt,publishedAt,url,assets \
    --jq '{name, tag: .tagName, target_commitish: .targetCommitish, body, draft: .isDraft, prerelease: .isPrerelease, created_at: .createdAt, published_at: .publishedAt, url, assets: [.assets[] | {name, size, url}]}' \
    | tee "$BACKUP_ROOT/releases/$tag/metadata.json"
  # 同时保留 GitHub 原始 Release API JSON，覆盖作者、正文、目标提交和资产 API 元数据，便于必要时恢复。
  gh api "repos/$OLD_ARCHIVE_REPO/releases/tags/$tag" \
    > "$BACKUP_ROOT/releases/$tag/release-api.json"
  gh release download "$tag" --repo "$OLD_ARCHIVE_REPO" \
    --dir "$BACKUP_ROOT/releases/$tag" --clobber
  find "$BACKUP_ROOT/releases/$tag" -type f -print | sort
done

# 记录备份文件摘要，尤其确认每个 Release 的 checksum/sha256 sidecar 已落盘。
(
  cd "$BACKUP_ROOT"
  find . -type f ! -name 'SHA256SUMS.txt' -print | LC_ALL=C sort | \
    while IFS= read -r path; do shasum -a 256 "$path"; done
) > "$BACKUP_ROOT/SHA256SUMS.txt"
rg -n -i 'checksum|sha256|\.sha256' "$BACKUP_ROOT/releases"
```

**确认点 1（不得跳过）**：维护者和第二位复核者共同确认：8 个版本（`v0.1.0`–`v0.1.4`、`v0.2.0`–`v0.2.2`）的 tag 和 Release 均存在；`expected-tags.txt` 与 `actual-release-tags.txt` 无差异；每个 Release 的 `metadata.json` 和 `release-api.json` 已保存正文、目标提交、发布状态、时间、作者与附件元数据，附件及 checksum 与线上记录一致；`mimi-remote-history.bundle`、Release 目录和 `SHA256SUMS.txt` 已复制到离线介质并可独立读取。确认记录完成前，不得删除旧归档仓库。

### 阶段二：维护窗口内删除、改名与切换

先冻结发布操作，确认本 PR 已合并到当前完整源码仓库的默认分支，GitHub Actions 必要检查全绿，且阶段一备份已签字。下面的删除和改名命令只是执行模板，必须由维护者在确认点后手动运行。

```bash
set -euo pipefail

OLD_ARCHIVE_REPO="gaixianggeng/mimi-remote"
SOURCE_REPO="gaixianggeng/codex-ipad-agent"
NEW_REPO="gaixianggeng/mimi-remote"
PR_NUMBER="<填写 MIM-20 PR 编号>"

# 确认点 2：PR 已合并、默认分支检查全绿、阶段一备份可读。
[[ "$PR_NUMBER" =~ ^[0-9]+$ ]] \
  || { echo "请先填写真实的 MIM-20 PR 编号。" >&2; exit 1; }
pr_state="$(gh pr view "$PR_NUMBER" --repo "$SOURCE_REPO" --json state --jq '.state')"
pr_base="$(gh pr view "$PR_NUMBER" --repo "$SOURCE_REPO" --json baseRefName --jq '.baseRefName')"
pr_merged_at="$(gh pr view "$PR_NUMBER" --repo "$SOURCE_REPO" --json mergedAt --jq '.mergedAt // ""')"
[[ "$pr_state" == "MERGED" && "$pr_base" == "main" && -n "$pr_merged_at" ]] \
  || { echo "维护窗口已停止：MIM-20 PR 必须已合并到 main，且 mergedAt 不得为空。" >&2; exit 1; }
gh pr checks "$PR_NUMBER" --repo "$SOURCE_REPO"
read -r -p "确认删除历史 $OLD_ARCHIVE_REPO（不可恢复）？输入 DELETE-ARCHIVE：" answer
[[ "$answer" == "DELETE-ARCHIVE" ]]

# 先删除历史归档，再立即把当前完整源码仓库改名为 mimi-remote。
gh repo delete "$OLD_ARCHIVE_REPO" --yes
gh api --method PATCH "repos/$SOURCE_REPO" -f name=mimi-remote

# 补齐 GitHub 搜索入口；Topics 只使用与当前能力一致的发现关键词。
gh repo edit "$NEW_REPO" \
  --description "Native iPhone and iPad remote workspace for Codex and Claude Code running on your Mac." \
  --add-topic codex \
  --add-topic claude-code \
  --add-topic ios \
  --add-topic ipad \
  --add-topic remote-development \
  --add-topic self-hosted

# 每个本地 clone 都更新 origin；下例保留当前 clone 使用的 SSH 传输方式。
# 使用 HTTPS 的 clone 应改为等价的 https://github.com/gaixianggeng/mimi-remote.git。
git remote set-url origin "git@github.com:gaixianggeng/mimi-remote.git"
git remote get-url origin
```

当前 Homebrew Formula 的 `v0.2.13` 下载地址仍使用改名前的源码仓库 URL。改名后 GitHub redirect 可短期保证下载可用，但 canonical 身份仍需在 Tap 中显式更新。维护者应在独立 Tap 分支替换 homepage 和所有 Release URL，保留版本与 SHA-256 不变，检查 diff 后创建并合并 Tap PR：

```bash
set -euo pipefail

tap_root="$(mktemp -d)"
gh repo clone gaixianggeng/homebrew-tap "$tap_root/homebrew-tap"
git -C "$tap_root/homebrew-tap" switch -c chore/mim-20-mimi-remote-repository-url

formula="$tap_root/homebrew-tap/Formula/mimi-remote.rb"
perl -pi -e \
  's#https://github\.com/gaixianggeng/codex-ipad-agent#https://github.com/gaixianggeng/mimi-remote#g' \
  "$formula"
ruby -c "$formula"
rg -n 'homepage|releases/download' "$formula"
git -C "$tap_root/homebrew-tap" diff --check
git -C "$tap_root/homebrew-tap" diff -- Formula/mimi-remote.rb

# 人工确认只有仓库 URL 变化，version 和 sha256 完全不变后再提交并创建 Tap PR。
git -C "$tap_root/homebrew-tap" add Formula/mimi-remote.rb
git -C "$tap_root/homebrew-tap" commit -m "MIM-20 update Mimi Remote repository URLs"
git -C "$tap_root/homebrew-tap" push -u origin chore/mim-20-mimi-remote-repository-url
gh pr create \
  --repo gaixianggeng/homebrew-tap \
  --head chore/mim-20-mimi-remote-repository-url \
  --title "MIM-20 update Mimi Remote repository URLs" \
  --body "Update the Formula homepage and release URLs after the canonical repository rename; version and checksums are unchanged."
```

立即执行下列核对。只要某一项失败，就停止发布，不要创建新 tag 或补传附件：

```bash
set -euo pipefail

NEW_REPO="gaixianggeng/mimi-remote"
OLD_SOURCE_URL="https://github.com/gaixianggeng/codex-ipad-agent"
NEW_SOURCE_URL="https://github.com/gaixianggeng/mimi-remote"

# 旧完整源码 URL 应重定向到新仓库；历史归档删除后的旧归档 URL 不承诺可恢复。
curl -fsSIL --max-redirs 3 "$OLD_SOURCE_URL" | rg -i '^(HTTP/|location:)'

# 新仓库必须可以匿名 clone，并包含默认分支与当前源码。
clone_dir="$(mktemp -d)"
git clone --filter=blob:none "$NEW_SOURCE_URL.git" "$clone_dir/mimi-remote"
git -C "$clone_dir/mimi-remote" status --short --branch

# Release、Actions、仓库描述和 Topics 均核对新身份。
gh release list --repo "$NEW_REPO" --limit 20
gh release view v0.2.13 --repo "$NEW_REPO" \
  --json tagName,isDraft,isPrerelease,publishedAt,url,assets
gh run list --repo "$NEW_REPO" --limit 20
gh repo view "$NEW_REPO" --json nameWithOwner,description,repositoryTopics,defaultBranchRef

# Homebrew Formula 必须继续使用 mimi-remote，并把下载 URL 指向新 Release。
gh api repos/gaixianggeng/homebrew-tap/contents/Formula/mimi-remote.rb \
  --jq '.download_url'
curl -fsSL \
  https://raw.githubusercontent.com/gaixianggeng/homebrew-tap/main/Formula/mimi-remote.rb \
  | rg -n 'github\.com/gaixianggeng/mimi-remote(/releases/download/|\")'
```

**确认点 3（切换完成）**：确认旧完整源码 URL 重定向到新地址；新仓库可匿名 clone；默认分支、Release 附件、Actions workflow、描述和 Topics 正确；Homebrew Formula 的 homepage、版本和 checksum 指向新 Release。确认完成后才恢复常规发布。

### App Store Connect 核对

仓库改名不会自动更新 App Store Connect 元数据。维护者必须在 App Store Connect 手工确认以下值，且不要把仓库迁移当作已完成的商店提交：

| Locale | Name | Subtitle |
| --- | --- | --- |
| en-US | `Mimi Remote` | `Remote coding workspace` |
| zh-Hans | `咪咪 Remote` | `AI 编程远程工作台` |

同时核对 Privacy Policy、Support、Terms URL 指向 `https://github.com/gaixianggeng/mimi-remote/blob/main/docs/...`，并确认 App Store 名称、URL 和实际构建能力一致。

## 风险与优化

- 删除 `gaixianggeng/mimi-remote` 不可恢复；旧历史 Release 的 URL 和资产不会自动迁移。默认策略是只保留阶段一的离线备份；如果要把历史资产重新发布到新仓库，必须另行评估、审批和执行，不能在本窗口顺手补发。
- `gaixianggeng/codex-ipad-agent` 改名后的旧完整源码 URL 通常会由 GitHub 重定向，但重定向不能替代本地 remote、Webhook、Deploy Key、Actions Secret、Branch protection、Issue/PR 自动化和 Homebrew Formula 的逐项核对。
- 删除旧归档后若改名 API 失败，应停止发布并记录 GitHub 返回值；不要创建同名临时仓库、不要移动 tag、不要伪造 Release 资产。恢复路径只能由仓库所有者根据离线备份另行决策。
- 仓库描述、Topics、Actions 和 App Store Connect 元数据属于独立外部状态；本 PR 只提供可执行清单，不代表这些状态已经更新。
- 离线备份可能包含历史公开资产和元数据，仍应按受控资料保存并定期验证摘要；不得把 Token、私有 Endpoint、账号或本机路径写入备份说明。
