#!/bin/bash
# =============================================================================
# 荣耀 50 SE (JLH-AN00) 华为内核兼容性修复脚本
# =============================================================================
# 【文件用途】
# 华为/荣耀的开源内核有大量残缺：删除了标准头文件、源码、改了参数名等。
# 本脚本在工作流的「Extra Kernel Options」步骤运行，修复这些问题让内核能编译。
#
# 【为什么需要】
# SUSFS 通用补丁是基于标准 Linux 内核写的，但华为内核有大量魔改：
#   - 删除了 netfilter 标准头文件（约 60+ 个）
#   - connectivity Makefile 的路径在 CI 环境解析错误（需加 $(abspath)）
#   - 改了 stat.c 的参数名（flag → flags）
#   - smap_gather_stats 函数签名改了（void 而非 int）
#   - 启用了 -Werror（警告即错误）
# 这些都会导致编译失败，必须逐个修复。
#
# 【换机型说明】
#   - 如果换成非华为机型，可以删除本脚本
#   - 如果换成其他华为机型，需要根据新机型的残缺情况调整
#   - 大部分修复是通用的华为内核问题，可直接复用
# =============================================================================
set -euxo pipefail
cd $GITHUB_WORKSPACE/device_kernel

# =============================================================================
# 修复 1: srctree 路径绝对化（修复 connectivity 符号链接路径错误）
# =============================================================================
# 问题: 华为内核 Makefile 里 srctree 用相对路径 ".."，导致 connectivity 驱动的
#        符号链接在 CI 环境里路径解析错误，编译时找不到头文件。
# 修复: 把 srctree 改成绝对路径 $(abspath ..)，让所有相对路径都基于源码根目录。
# 原理: $(abspath ..) 是 GNU Make 函数，会把 ".." 转成绝对路径。
#       这样后续的 $(srctree)/path 都能正确解析。
sed -i 's|srctree := \.\.|srctree := $(abspath ..)|' Makefile

# =============================================================================
# 修复 2: 按作者 Wiki 方法修改 connectivity Makefile（关键！）
# =============================================================================
# 参考: https://github.com/JackA1ltman/NonGKI_Kernel_Build_2nd/wiki/en-Compiling-the-Stock-Vendor-Kernel
# 问题: connectivity Makefile 里 ABS_PATH_TO_*_DRV = $(srctree)/../$(PATH_TO_*_DRV)，
#        在 CI 环境 $(srctree) 解析为相对路径，导致符号链接指向错误位置，
#        编译时报 "bt/Makefile: No such file or directory"。
# 修复 (作者推荐):
#   2a. 把 $(srctree)/../$(PATH) 改成 $(abspath $(srctree)/../$(PATH))
#   2b. 把 ln -s 改成 ln -snf（符号链接已存在时不报错）
#   2c. 取消注释 BT 驱动段（华为内核把 BT 段注释掉了）
CONN_MK=drivers/misc/mediatek/connectivity/Makefile
# 2a. 给所有 $(srctree)/../$(PATH_TO_XXX) 加 $(abspath ...) 包裹
#     匹配完整的 $(srctree)/../$(PATH_TO_XXX) 表达式（含右括号），
#     仅处理不含 abspath 的行（防止重复包裹）。
sed -i -E '/abspath/! s#(^|[^)])\$\(srctree\)/\.\./\$\(PATH_TO_([A-Z_]+)\)#\1$(abspath $(srctree)/../$(PATH_TO_\2))#g' "$CONN_MK"
# 2b. ln -s → ln -snf
sed -i 's|ln -s \$(ABS_PATH_TO_|ln -snf $(ABS_PATH_TO_|g' "$CONN_MK"
# 2c. 取消注释 BT 驱动段（华为内核把 BT 段注释掉了）
#     用 awk 处理 "For BT built-in mode start" 到 "For BT built-in mode end" 之间的所有行，
#     去掉行首的 "# "（但保留 @{/@} 标记行），同时把芯片过滤条件改为匹配 CONSYS_6877。
awk '
  /For BT built-in mode start/ { in_bt=1; print; next }
  /For BT built-in mode end/   { in_bt=0; print; next }
  in_bt && /^# / {
    line = substr($0, 3)
    # 把芯片过滤条件改成匹配 CONSYS_6877（或无条件）
    gsub(/CONSYS_6885/, "CONSYS_6877", line)
    print line
    next
  }
  { print }
' "$CONN_MK" > "$CONN_MK.tmp" && mv "$CONN_MK.tmp" "$CONN_MK"
# 兜底：确保 obj-y += bt/ 存在（可能 BT 段没有 ifneq 包裹）
grep -q '^obj-y += bt/' "$CONN_MK" || echo 'obj-y += bt/' >> "$CONN_MK"
echo "[+] connectivity Makefile patched (abspath + ln -snf + BT enabled)"

# =============================================================================
# 修复 3: 把 connectivity 驱动移到 vendor/ 目录
# =============================================================================
# 问题: 华为开源内核把 connectivity 驱动放在 drivers/misc/mediatek/connectivity/，
#        但 connectivity Makefile 的 PATH_TO_*_DRV 指向 vendor/mediatek/kernel_modules/connectivity/。
# 修复: 把 7 个子目录移到 vendor/ 对应位置，并在原位置创建符号链接。
# 注意: connectivity Makefile 会为 wmt_drv/bt/fmradio/gps_drv/wmt_chrdev_wifi/wlan_drv_gen4m
#       自己创建符号链接，但不会为 common 创建，因此 common 的符号链接必须由本脚本创建。
VENDOR="$GITHUB_WORKSPACE/vendor/mediatek/kernel_modules/connectivity"
declare -A MAP=(
  [wmt_drv]="conninfra"
  [wmt_chrdev_wifi]="wlan/adaptor"
  [wlan_drv_gen4m]="wlan/core/gen4m"
  [bt]="bt/mt66xx/connac2"
  [fmradio]="fmradio"
  [gps_drv]="gps"
  [common]="common"
)
for SRC_NAME in "${!MAP[@]}"; do
  SRC_PATH="drivers/misc/mediatek/connectivity/$SRC_NAME"
  DST_PATH="$VENDOR/${MAP[$SRC_NAME]}"
  mkdir -p "$(dirname "$DST_PATH")"
  if [ -e "$SRC_PATH" ] || [ -L "$SRC_PATH" ]; then
    rm -rf "$DST_PATH"
    mv "$SRC_PATH" "$DST_PATH"
  fi
  rm -rf "$SRC_PATH"
  ln -snf "$DST_PATH" "$SRC_PATH"
  # 验证：目标目录的 Makefile 必须存在
  if [ -f "$DST_PATH/Makefile" ]; then
    echo "$SRC_NAME: OK -> $DST_PATH (Makefile exists)"
  else
    echo "$SRC_NAME: WARN -> $DST_PATH (NO Makefile at target!)"
  fi
done

# =============================================================================
# 修复 4: 脚本执行权限
# =============================================================================
# 问题: Git 仓库有时不保留文件执行权限，导致脚本无法运行。
# 修复: 给所有脚本文件加 +x 权限。
chmod +x scripts/clang-android.sh
chmod +x arch/arm64/kernel/vdso/gen_vdso_offsets.sh
chmod +x tools/build/cpio
chmod +x scripts/dtc/dtc_overlay
find tools/ -type f -name "*.sh" -exec chmod +x {} \;

# =============================================================================
# 修复 5: SUSFS 补丁兼容性（部分由 Fixed 补丁处理，这里处理剩余的）
# =============================================================================
# 注意: fdinfo.c 的 inotify 隐藏功能由 susfs_fixed.patch 处理，
#       这里只处理 stat.c 和 task_mmu.c 的两个小问题。

# 4.1 修复 stat.c 的参数名 flag → flags
# 问题: SUSFS 通用补丁期望 ksu_handle_stat 的第三个参数是 flag（单数），
#        但华为内核改成了 flags（复数）。补丁应用后变量名不匹配会编译错误。
# 修复: 把 SUSFS 补丁里的 flag 单数形式改成 flags 复数，匹配华为内核。
# 原理: sed 直接替换字符串，& 在 sed 里是特殊字符要转义。
sed -i 's/ksu_handle_stat(&dfd, &fname, &flag)/ksu_handle_stat(\&dfd, \&fname, \&flags)/' fs/stat.c

# 4.2 修复 task_mmu.c 的 smap_gather_stats 返回值
# 问题: SUSFS 通用补丁在 smap_gather_stats 函数里加了 return 0;，
#        但华为内核这个函数是 void 返回类型，写 return 0; 会报错：
#          error: void function 'smap_gather_stats' should not return a value
# 修复: 把 smap_gather_stats 函数里的 return 0; 改成 return;（不带值）。
# 原理: 用 Python 脚本解析函数体，定位函数边界（通过花括号深度），
#       在函数范围内把 return 0; 替换为 return;。
#       不用 sed 是因为 return 0; 在其他函数里也有，不能全局替换。
python3 -c "
import re
with open('fs/proc/task_mmu.c') as f:
    lines = f.readlines()
in_func = False
found_brace = False
brace_depth = 0
out = []
for line in lines:
    # 检测进入 smap_gather_stats 函数（函数签名行）
    if not in_func and re.search(r'\bsmap_gather_stats\s*\(', line):
        in_func = True
    if in_func:
        # 跟踪花括号深度，定位函数体范围
        if not found_brace and '{' in line:
            found_brace = True
            brace_depth = line.count('{') - line.count('}')
        elif found_brace:
            brace_depth += line.count('{') - line.count('}')
            # 在函数体内，把 return 0; 替换为 return;
            if 'return 0;' in line:
                line = line.replace('return 0;', 'return;')
            # 花括号闭合，说明函数结束
            if brace_depth <= 0:
                in_func = False
                found_brace = False
    out.append(line)
with open('fs/proc/task_mmu.c', 'w') as f:
    f.writelines(out)
"

# =============================================================================
# 修复 6: 禁用 WERROR（华为内核启用了 -Werror，警告即错误）
# =============================================================================
# 问题: 华为内核在 Makefile 里启用了 -Werror，所有警告都会被当作错误，
#        编译会因为一些无关紧要的警告（如未使用变量）而失败。
# 修复: 把所有 Makefile 里的 -Werror 替换为 -Wno-error（警告但不报错）。
# 原理: find + sed 递归处理所有 Makefile 文件。
find . -name "Makefile" -exec sed -i 's/-Werror/-Wno-error/g' {} +

# 5a.1 禁用 Clang 对 strcpy 的 stpcpy 优化
# 问题: Clang 编译时会自动把 strcpy 优化成 stpcpy（更高效的变体），
#        但 Linux 内核没有实现 stpcpy 函数，链接时会报 undefined symbol。
# 修复: 给 KBUILD_CFLAGS 加 -fno-builtin-stpcpy，禁用这个优化。
# 原理: -fno-builtin-XXX 告诉编译器不要把 XXX 当作内置函数优化。
sed -i 's/^KBUILD_CFLAGS\s*+=/KBUILD_CFLAGS += -fno-builtin-stpcpy /' Makefile
# 兜底: 如果上面没匹配到，追加一行
grep -q "fno-builtin-stpcpy" Makefile || echo 'KBUILD_CFLAGS += -fno-builtin-stpcpy' >> Makefile

# =============================================================================
# 修复 7: netfilter 模块禁用 + 头文件补全
# =============================================================================
# 问题: 华为开源内核删除了 netfilter 下的部分模块源码（如 xt_TCPMSS.c），
#        但 defconfig 里仍然 CONFIG_NETFILTER_XT_TARGET_TCPMSS=y，
#        编译时会找不到源码而报错。同时华为还删除了 include/linux/netfilter/
#        下的约 60+ 个标准头文件，导致其他模块引用时报错。
# 修复:
#   6.1 在 Makefile 注释掉 xt_TCPMSS 的编译行
#   6.2 为缺失的头文件创建"包装头文件"（include <uapi/...>）

# 6.1 禁用 xt_TCPMSS 模块（源码被华为删除）
sed -i 's/^obj-\$(CONFIG_NETFILTER_XT_TARGET_TCPMSS).*/#obj-\$(CONFIG_NETFILTER_XT_TARGET_TCPMSS) += xt_TCPMSS.o/' net/netfilter/Makefile

# 6.2 创建缺失的 netfilter 包装头文件
# 说明: include/linux/netfilter/ 下的头文件应该是"包装器"，内容是 #include <uapi/...>。
#       华为把这些都删了，我们用脚本批量重建。
# 原理: 对每个缺失的头文件，去 include/uapi/linux/netfilter/ 找对应的（忽略大小写），
#       然后写一个 #include <uapi/...> 的包装文件。
mkdir -p include/linux/netfilter
for hdr in nf_conntrack_tuple_common.h nf_log.h nf_nat.h nf_tables.h nf_tables_compat.h \
           nfnetlink_compat.h nfnetlink_conntrack.h nfnetlink_cthelper.h nfnetlink_cttimeout.h \
           nfnetlink_log.h nfnetlink_queue.h \
           xt_AUDIT.h xt_CHECKSUM.h xt_CLASSIFY.h xt_CONNSECMARK.h xt_CT.h xt_DSCP.h \
           xt_HMARK.h xt_IDLETIMER.h xt_LED.h xt_LOG.h xt_NFLOG.h xt_NFQUEUE.h xt_RATEEST.h \
           xt_SECMARK.h xt_SYNPROXY.h xt_TCPOPTSTRIP.h xt_TEE.h xt_TPROXY.h \
           xt_addrtype.h xt_bpf.h xt_cgroup.h xt_cluster.h xt_comment.h xt_connbytes.h \
           xt_connlimit.h xt_conntrack.h xt_cpu.h xt_dccp.h xt_devgroup.h \
           xt_ecn.h xt_esp.h xt_helper.h xt_ipcomp.h xt_iprange.h xt_ipvs.h \
           xt_l2tp.h xt_length.h xt_limit.h xt_mac.h xt_mark.h xt_multiport.h xt_nfacct.h \
           xt_osf.h xt_owner.h xt_pkttype.h xt_policy.h xt_quota.h xt_realm.h xt_recent.h \
           xt_rpfilter.h xt_sctp.h xt_set.h xt_socket.h xt_state.h xt_statistic.h \
           xt_string.h xt_tcpmss.h xt_tcpudp.h xt_time.h xt_u32.h; do
  [ -f "include/linux/netfilter/$hdr" ] && continue
  # 在 uapi 目录找对应文件（忽略大小写，因为 xt_AUDIT.h 对应 uapi/xt_audit.h）
  uapi_name=$(find include/uapi/linux/netfilter/ -iname "$hdr" 2>/dev/null | head -1 | xargs basename 2>/dev/null)
  if [ -n "$uapi_name" ]; then
    echo "#include <uapi/linux/netfilter/$uapi_name>" > "include/linux/netfilter/$hdr"
  fi
done

# 6.3 xt_connmark.h 需要完整定义（uapi 版本只是包装它，不能循环引用）
# 说明: xt_connmark.h 不能简单 #include <uapi/...>，因为 uapi 版本会反向引用它，
#       会造成循环引用。所以这里直接给出完整定义。
if [ ! -f include/linux/netfilter/xt_connmark.h ]; then
cat > include/linux/netfilter/xt_connmark.h <<'EOF'
#ifndef _XT_CONNMARK_H
#define _XT_CONNMARK_H
#include <linux/types.h>
enum {
	XT_CONNMARK_SET = 0,
	XT_CONNMARK_SAVE,
	XT_CONNMARK_RESTORE
};
struct xt_connmark_tginfo1 {
	__u32 ctmark, ctmask, nfmask;
	__u8 mode;
};
struct xt_connmark_mtinfo1 {
	__u32 mark, mask;
	__u8 invert;
};
#endif
EOF
fi

# 6.4 xt_dscp.h 需要完整定义（uapi/xt_DSCP.h 和 uapi/xt_ecn.h 都引用它）
if [ ! -f include/linux/netfilter/xt_dscp.h ]; then
cat > include/linux/netfilter/xt_dscp.h <<'EOF'
#ifndef _XT_DSCP_H
#define _XT_DSCP_H
#include <linux/types.h>
#define XT_DSCP_MASK	0xfc
#define XT_DSCP_SHIFT	2
#define XT_DSCP_MAX	0x3f
struct xt_dscp_info {
	__u8 dscp;
	__u8 invert;
};
struct xt_tos_match_info {
	__u8 tos_mask;
	__u8 tos_value;
	__u8 invert;
};
#endif
EOF
fi

# =============================================================================
# 修复 8: conninfra 头文件路径自动补全（不创建 stub！）
# =============================================================================
# 之前的错误做法: 凭空创建了 wmt_exp.h、stp_exp.h、osal_typedef.h 等 12 个 stub 头文件
#                和 wmt_stp_stub.c，实际上这些文件很可能本来就在 conninfra 源码树里，
#                只是 Makefile 的 include 路径没覆盖到。构建日志也证实从未报这些头文件缺失。
# 正确做法:
#   8.1 扫描 conninfra 目录下所有 */include 子目录，全部加入 ccflags-y
#   8.2 不创建任何 stub 头文件。如果编译真的报缺头文件，再针对性处理。
#   8.3 给 wlan/adaptor 也加上 conninfra 的 include 路径
CONNINFRA_DIR="$VENDOR/conninfra"
CONNINFRA_MK="$CONNINFRA_DIR/Makefile"

# 8.1 收集 conninfra 下所有 include 目录，追加到 Makefile
if [ -f "$CONNINFRA_MK" ]; then
  # 找出所有名为 include 的目录（相对于 conninfra）
  INCLUDE_DIRS=$(find "$CONNINFRA_DIR" -type d -name include 2>/dev/null | sort)
  echo "[+] conninfra include dirs found:"
  echo "$INCLUDE_DIRS"
  # 把每个 include 目录转成 -I$(TOP)/vendor/.../include 追加到 Makefile
  for incdir in $INCLUDE_DIRS; do
    rel_path="${incdir#$GITHUB_WORKSPACE/}"
    grep -q "$rel_path" "$CONNINFRA_MK" || echo "ccflags-y += -I\$(TOP)/$rel_path" >> "$CONNINFRA_MK"
  done
  echo "[+] conninfra Makefile: added all include paths"
fi

# 8.2 给 wlan/adaptor 的 Makefile 加 conninfra 的 include 路径
WMT_MK="$VENDOR/wlan/adaptor/Makefile"
if [ -f "$WMT_MK" ]; then
  for incdir in $INCLUDE_DIRS; do
    rel_path="${incdir#$GITHUB_WORKSPACE/}"
    grep -q "$rel_path" "$WMT_MK" || echo "ccflags-y += -I\$(TOP)/$rel_path" >> "$WMT_MK"
  done
  echo "[+] wlan/adaptor Makefile: added conninfra include paths"
fi

# 8.3 验证：在整个内核源码树搜索关键头文件
# 说明: 之前只在 conninfra 目录搜，范围太窄。
#       这些头文件可能在 drivers/misc/mediatek/connectivity/ 的其他子目录，
#       或在 drivers/misc/mediatek/include/ 等位置。
#       先在整个源码树搜索，找到的就加入 include 路径，不用创建 stub。
KERNEL_SRC="$GITHUB_WORKSPACE/device_kernel"
echo "[+] Searching for conninfra headers in entire source tree:"
FOUND_HEADERS=""   # 记录找到的头文件及其目录
MISSING_HEADERS="" # 记录确实不存在的头文件
for hdr in wmt_exp.h stp_exp.h osal_typedef.h wmt_core.h wmt_dev.h wmt_task.h \
           conninfra_ext.h mtk_wcn_consys_hw.h consys_hw.h conninfra_core.h; do
  # 在整个内核源码树搜索（不限于 conninfra）
  found=$(find "$KERNEL_SRC" "$GITHUB_WORKSPACE/vendor" -name "$hdr" 2>/dev/null | head -1)
  if [ -n "$found" ]; then
    found_dir=$(dirname "$found")
    echo "  FOUND: $hdr -> ${found#$GITHUB_WORKSPACE/}"
    # 如果找到的目录不在已知 include 路径中，记录下来
    FOUND_HEADERS="$FOUND_HEADERS $found_dir:$hdr"
  else
    echo "  MISSING: $hdr (not found anywhere in source tree)"
    MISSING_HEADERS="$MISSING_HEADERS $hdr"
  fi
done

# 8.3b 如果头文件在源码树其他位置找到，把那些目录加入 include 路径
if [ -n "$FOUND_HEADERS" ]; then
  echo "[+] Adding include paths for found headers..."
  # 收集所有找到的目录（去重）
  FOUND_DIRS=$(echo "$FOUND_HEADERS" | tr ' ' '\n' | cut -d: -f1 | sort -u)
  for fdir in $FOUND_DIRS; do
    rel_path="${fdir#$GITHUB_WORKSPACE/}"
    # 加到 conninfra Makefile
    if [ -f "$CONNINFRA_MK" ]; then
      grep -q "$rel_path" "$CONNINFRA_MK" || echo "ccflags-y += -I\$(TOP)/$rel_path" >> "$CONNINFRA_MK"
    fi
    # 加到 wlan/adaptor Makefile
    if [ -f "$WMT_MK" ]; then
      grep -q "$rel_path" "$WMT_MK" || echo "ccflags-y += -I\$(TOP)/$rel_path" >> "$WMT_MK"
    fi
    echo "  + added include: $rel_path"
  done
fi

# 8.4 只为全源码树搜索后仍确认缺失的头文件创建 stub
# 说明: 只有经 8.3 在整个源码树搜索后仍 MISSING 的文件才创建 stub。
#       如果在源码树找到了，用 8.3b 的 include 路径解决，不创建 stub。
CONNINFRA_INC="$CONNINFRA_DIR/include"
mkdir -p "$CONNINFRA_INC"

if [ -z "$MISSING_HEADERS" ]; then
  echo "[+] All conninfra headers found in source tree - no stubs needed"
else
  echo "[+] Creating stubs for headers confirmed missing: $MISSING_HEADERS"

# osal_typedef.h - OS 抽象层基础类型（被所有驱动引用）
if echo "$MISSING_HEADERS" | grep -qw "osal_typedef.h"; then
cat > "$CONNINFRA_INC/osal_typedef.h" <<'EOF'
#ifndef _OSAL_TYPEDEF_H
#define _OSAL_TYPEDEF_H
#include <linux/types.h>
#include <linux/spinlock.h>
typedef unsigned char   OSAL_UINT8;
typedef signed char     OSAL_SINT8;
typedef unsigned short  OSAL_UINT16;
typedef signed short    OSAL_SINT16;
typedef unsigned int    OSAL_UINT32;
typedef signed int      OSAL_SINT32;
typedef unsigned long long OSAL_UINT64;
typedef long long       OSAL_SINT64;
typedef void            OSAL_VOID;
typedef int             OSAL_BOOL;
typedef char            OSAL_CHAR;
typedef unsigned long   OSAL_ULONG;
#define OSAL_NULL       NULL
#define OSAL_FALSE      0
#define OSAL_TRUE       1
#endif
EOF
echo "[+] Created osal_typedef.h (stub)"
fi

# wmt_exp.h - conninfra 对 wlan/bt/fm/gps 导出的核心接口
if echo "$MISSING_HEADERS" | grep -qw "wmt_exp.h"; then
cat > "$CONNINFRA_INC/wmt_exp.h" <<'EOF'
#ifndef _WMT_EXP_H
#define _WMT_EXP_H
#include <linux/types.h>
#include "osal_typedef.h"
#define CFG_WMT_PS_TASK_HANDLER  (0)
#define BT_TASK_INDX             (0)
#define FM_TASK_INDX             (1)
#define GPS_TASK_INDX            (2)
#define WIFI_TASK_INDX           (3)
#define WMT_TASK_INDX            (4)
#define STP_TASK_INDX            (5)
#define WMT_DEV_ID_BT            (0)
#define WMT_DEV_ID_FM            (1)
#define WMT_DEV_ID_GPS           (2)
#define WMT_DEV_ID_WIFI          (3)
#define WMT_DEV_ID_STP           (4)
#define WMT_DEV_ID_WMT           (5)
#define WMT_DRV_NAME             "wmt_drv"
typedef enum {
	STA_PWR_OFF = 0,
	STA_PWR_ON,
	STA_PWR_STBY,
	STA_PWR_MAX
} WMT_PWR_STATE;
typedef void (*wmt_dev_irq_cb)(void);
typedef int32_t (*wmt_dev_tx_cb)(uint8_t *buf, uint32_t len);
int32_t wmt_export_init(void);
int32_t wmt_export_deinit(void);
int32_t wmt_dev_req_power_on(uint8_t dev_id);
int32_t wmt_dev_req_power_off(uint8_t dev_id);
int32_t wmt_dev_req_assert(uint8_t dev_id);
int32_t wmt_dev_req_host_wakeup(uint8_t dev_id, uint8_t wake);
int32_t wmt_dev_reg_tx_cb(uint8_t dev_id, wmt_dev_tx_cb cb);
int32_t wmt_dev_reg_irq_cb(uint8_t dev_id, wmt_dev_irq_cb cb);
int32_t wmt_dev_rx_from_stp(uint8_t *buf, uint32_t len);
int32_t wmt_dev_tx_to_stp(uint8_t dev_id, uint8_t *buf, uint32_t len);
int32_t wmt_plat_set_rst_ctrl(uint8_t level);
int32_t wmt_plat_set_pwr_ctrl(uint8_t level);
int32_t wmt_plat_set_ldo_ctrl(uint8_t level);
int32_t wmt_plat_set_rtc_ctrl(uint8_t level);
int32_t wmt_plat_set_all_pwr_off(void);
uint32_t wmt_plat_get_pm_state(void);
void wmt_plat_set_therm_ctrl(int32_t level);
int32_t wmt_wifi_modify_para(uint8_t *buf, uint32_t len);
#endif
EOF
echo "[+] Created wmt_exp.h (stub)"
fi

# stp_exp.h - STP 传输层导出接口（被 bt/fm 引用）
if echo "$MISSING_HEADERS" | grep -qw "stp_exp.h"; then
cat > "$CONNINFRA_INC/stp_exp.h" <<'EOF'
#ifndef _STP_EXP_H
#define _STP_EXP_H
#include <linux/types.h>
#include "osal_typedef.h"
typedef int32_t (*stp_rx_cb_t)(uint8_t *buf, uint32_t len, void *priv);
int32_t stp_exp_register_if(uint8_t type, stp_rx_cb_t rx_cb, void *priv);
int32_t stp_exp_unregister_if(uint8_t type);
int32_t stp_exp_send_data(uint8_t type, uint8_t *buf, uint32_t len);
int32_t stp_exp_is_enable(void);
int32_t stp_exp_poll_data(uint8_t type, uint8_t *buf, uint32_t len);
#endif
EOF
echo "[+] Created stp_exp.h (stub)"
fi

# wmt_core.h - WMT 核心数据结构
if echo "$MISSING_HEADERS" | grep -qw "wmt_core.h"; then
cat > "$CONNINFRA_INC/wmt_core.h" <<'EOF'
#ifndef _WMT_CORE_H
#define _WMT_CORE_H
#include <linux/types.h>
#include "osal_typedef.h"
#define MTK_WCN_WMT_THREAD_NAME "wmt_thread"
#define MTK_WCN_WMT_MAX_RETRY_CNT (5)
typedef struct _WMT_DEV_ {
	int32_t fd;
	void *private_data;
} WMT_DEV, *P_WMT_DEV;
#endif
EOF
echo "[+] Created wmt_core.h (stub)"
fi

# wmt_dev.h - WMT 设备操作接口
if echo "$MISSING_HEADERS" | grep -qw "wmt_dev.h"; then
cat > "$CONNINFRA_INC/wmt_dev.h" <<'EOF'
#ifndef _WMT_DEV_H
#define _WMT_DEV_H
#include <linux/types.h>
#include "osal_typedef.h"
int32_t wmt_dev_init(void);
int32_t wmt_dev_deinit(void);
int32_t wmt_dev_open(uint8_t dev_id);
int32_t wmt_dev_close(uint8_t dev_id);
#endif
EOF
echo "[+] Created wmt_dev.h (stub)"
fi

# wmt_task.h - WMT 任务/线程接口
if echo "$MISSING_HEADERS" | grep -qw "wmt_task.h"; then
cat > "$CONNINFRA_INC/wmt_task.h" <<'EOF'
#ifndef _WMT_TASK_H
#define _WMT_TASK_H
#include <linux/types.h>
#include "osal_typedef.h"
typedef void (*wmt_task_handler_t)(void *data);
int32_t wmt_task_create(uint8_t task_id, wmt_task_handler_t handler, void *data);
int32_t wmt_task_destroy(uint8_t task_id);
int32_t wmt_task_send_msg(uint8_t task_id, uint32_t msg, uint8_t *data, uint32_t len);
#endif
EOF
echo "[+] Created wmt_task.h (stub)"
fi

# conninfra_ext.h - conninfra 对外部的扩展接口
if echo "$MISSING_HEADERS" | grep -qw "conninfra_ext.h"; then
cat > "$CONNINFRA_INC/conninfra_ext.h" <<'EOF'
#ifndef _CONNINFRA_EXT_H
#define _CONNINFRA_EXT_H
#include <linux/types.h>
#include "osal_typedef.h"
int32_t conninfra_ext_init(void);
int32_t conninfra_ext_deinit(void);
int32_t conninfra_ext_power_on(uint8_t dev_id);
int32_t conninfra_ext_power_off(uint8_t dev_id);
#endif
EOF
echo "[+] Created conninfra_ext.h (stub)"
fi

# mtk_wcn_consys_hw.h - 连接系统硬件相关定义
if echo "$MISSING_HEADERS" | grep -qw "mtk_wcn_consys_hw.h"; then
cat > "$CONNINFRA_INC/mtk_wcn_consys_hw.h" <<'EOF'
#ifndef _MTK_WCN_CONSYS_HW_H
#define _MTK_WCN_CONSYS_HW_H
#include <linux/types.h>
#include "osal_typedef.h"
#define CONSYS_CHIPID_UNKNOWN  (0)
#define CONSYS_CHIPID_6877     (1)
#define CONSYS_CHIPID_6885     (2)
#define CONSYS_CHIPID_6893     (3)
uint32_t mtk_wcn_consys_hw_get_chipid(void);
int32_t mtk_wcn_consys_hw_init(void);
void mtk_wcn_consys_hw_deinit(void);
#endif
EOF
echo "[+] Created mtk_wcn_consys_hw.h (stub)"
fi

fi  # end of MISSING_HEADERS check

# =============================================================================
# 修复 9: 禁用华为安全检测（防止 root 被检测）
# =============================================================================
# 问题: 华为内核启用了大量安全检测功能（HISI_PMALLOC、HIVIEW_SELINUX、
#        HUAWEI_EIMA 等 20+ 项），这些会检测 root 并触发反制（如重启、告警）。
#        作为自定义内核，需要全部禁用。
# 修复: 在 defconfig 里把这些 CONFIG_XXX=y 改成 # CONFIG_XXX is not set。
# 原理: sed 把 "CONFIG_XXX=y" 改成 "# CONFIG_XXX is not set"，
#       这是 Kconfig 的标准禁用语法。
DEFCONFIG=arch/arm64/configs/merge_full_k6877v1_64_defconfig

# 9.1 禁用华为安全/检测相关配置（全面覆盖，方便换机型）
# 说明: 以下是华为/荣耀内核常见的安全检测配置，覆盖多种机型。
#       本机型 defconfig 中可能只有部分存在，不存在的配置 sed 不会有效果，
#       但保留全部列表方便以后移植到其他华为机型时直接使用。
# 原理: sed 把 "CONFIG_XXX=y" 改成 "# CONFIG_XXX is not set"。
sed -i 's/^CONFIG_HISI_PMALLOC=y.*/# CONFIG_HISI_PMALLOC is not set/' $DEFCONFIG
sed -i 's/^CONFIG_HIVIEW_SELINUX=y.*/# CONFIG_HIVIEW_SELINUX is not set/' $DEFCONFIG
sed -i 's/^CONFIG_HISI_SELINUX_EBITMAP_RO=y.*/# CONFIG_HISI_SELINUX_EBITMAP_RO is not set/' $DEFCONFIG
sed -i 's/^CONFIG_HISI_SELINUX_PROT=y.*/# CONFIG_HISI_SELINUX_PROT is not set/' $DEFCONFIG
sed -i 's/^CONFIG_HISI_RO_LSM_HOOKS=y.*/# CONFIG_HISI_RO_LSM_HOOKS is not set/' $DEFCONFIG
sed -i 's/^CONFIG_INTEGRITY=y.*/# CONFIG_INTEGRITY is not set/' $DEFCONFIG
sed -i 's/^CONFIG_INTEGRITY_AUDIT=y.*/# CONFIG_INTEGRITY_AUDIT is not set/' $DEFCONFIG
sed -i 's/^CONFIG_HUAWEI_CRYPTO_TEST_MDPP=y.*/# CONFIG_HUAWEI_CRYPTO_TEST_MDPP is not set/' $DEFCONFIG
sed -i 's/^CONFIG_HUAWEI_SELINUX_DSM=y.*/# CONFIG_HUAWEI_SELINUX_DSM is not set/' $DEFCONFIG
sed -i 's/^CONFIG_HUAWEI_HIDESYMS=y.*/# CONFIG_HUAWEI_HIDESYMS is not set/' $DEFCONFIG
sed -i 's/^CONFIG_HW_SLUB_SANITIZE=y.*/# CONFIG_HW_SLUB_SANITIZE is not set/' $DEFCONFIG
sed -i 's/^CONFIG_HUAWEI_PROC_CHECK_ROOT=y.*/# CONFIG_HUAWEI_PROC_CHECK_ROOT is not set/' $DEFCONFIG
sed -i 's/^CONFIG_HW_ROOT_SCAN=y.*/# CONFIG_HW_ROOT_SCAN is not set/' $DEFCONFIG
sed -i 's/^CONFIG_HUAWEI_EIMA=y.*/# CONFIG_HUAWEI_EIMA is not set/' $DEFCONFIG
sed -i 's/^CONFIG_HUAWEI_EIMA_ACCESS_CONTROL=y.*/# CONFIG_HUAWEI_EIMA_ACCESS_CONTROL is not set/' $DEFCONFIG
sed -i 's/^CONFIG_HW_DOUBLE_FREE_DYNAMIC_CHECK=y.*/# CONFIG_HW_DOUBLE_FREE_DYNAMIC_CHECK is not set/' $DEFCONFIG
sed -i 's/^CONFIG_HKIP_ATKINFO=y.*/# CONFIG_HKIP_ATKINFO is not set/' $DEFCONFIG
sed -i 's/^CONFIG_HW_KERNEL_STP=y.*/# CONFIG_HW_KERNEL_STP is not set/' $DEFCONFIG
sed -i 's/^CONFIG_HISI_HHEE=y.*/# CONFIG_HISI_HHEE is not set/' $DEFCONFIG
sed -i 's/^CONFIG_HISI_HHEE_TOKEN=y.*/# CONFIG_HISI_HHEE_TOKEN is not set/' $DEFCONFIG
sed -i 's/^CONFIG_HISI_DIEID=y.*/# CONFIG_HISI_DIEID is not set/' $DEFCONFIG
sed -i 's/^CONFIG_HISI_SUBPMU=y.*/# CONFIG_HISI_SUBPMU is not set/' $DEFCONFIG
sed -i 's/^CONFIG_TEE_ANTIROOT_CLIENT=y.*/# CONFIG_TEE_ANTIROOT_CLIENT is not set/' $DEFCONFIG
sed -i 's/^CONFIG_HWAA=y.*/# CONFIG_HWAA is not set/' $DEFCONFIG

# =============================================================================
# 修复 10: 禁用被华为删除源码的内核模块（netfilter xt_TCPMSS）
# =============================================================================
# 问题: 同修复 6.1，defconfig 里也启用了 CONFIG_NETFILTER_XT_TARGET_TCPMSS，
#        需要在 defconfig 层面也禁用（光在 Makefile 注释不够）。
sed -i 's/^CONFIG_NETFILTER_XT_TARGET_TCPMSS=y.*/# CONFIG_NETFILTER_XT_TARGET_TCPMSS is not set/' $DEFCONFIG

echo "[+] All setup done."
