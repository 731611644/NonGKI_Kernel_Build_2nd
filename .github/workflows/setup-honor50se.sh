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
#   - 删除了 connectivity 驱动的部分头文件（wmt_exp.h 等）
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
# 修复 2: 把 connectivity 驱动移到 vendor/ 目录
# =============================================================================
# 问题: 华为开源内核把 connectivity 驱动放在 drivers/misc/mediatek/connectivity/，
#        但实际编译需要的路径是 vendor/mediatek/kernel_modules/connectivity/。
#        如果不移过去，Makefile 找不到正确的依赖关系。
# 修复: 把 6 个子驱动（wmt_drv、wmt_chrdev_wifi、wlan_drv_gen4m、bt、fmradio、gps_drv）
#        移到 vendor/ 目录下对应位置。
# 原理: 用关联数组 MAP 记录"源名 → 目标路径"映射，循环 mv。
# 注意: 只移动 conninfra（wmt_drv）会被实际编译，其他 wlan/bt/fm/gps 在修复 5b 中禁用。
VENDOR="$GITHUB_WORKSPACE/vendor/mediatek/kernel_modules/connectivity"
declare -A MAP=(
  [wmt_drv]="conninfra"
  [wmt_chrdev_wifi]="wlan/adaptor"
  [wlan_drv_gen4m]="wlan/core/gen4m"
  [bt]="bt/mt66xx/connac2"
  [fmradio]="fmradio"
  [gps_drv]="gps"
)
for SRC_NAME in "${!MAP[@]}"; do
  DST_PATH="$VENDOR/${MAP[$SRC_NAME]}"
  mkdir -p "$(dirname "$DST_PATH")"
  rm -rf "$DST_PATH"
  mv "drivers/misc/mediatek/connectivity/$SRC_NAME" "$DST_PATH"
done

# =============================================================================
# 修复 3: 脚本执行权限
# =============================================================================
# 问题: Git 仓库有时不保留文件执行权限，导致脚本无法运行。
# 修复: 给所有脚本文件加 +x 权限。
chmod +x scripts/clang-android.sh
chmod +x arch/arm64/kernel/vdso/gen_vdso_offsets.sh
chmod +x tools/build/cpio
chmod +x scripts/dtc/dtc_overlay
find tools/ -type f -name "*.sh" -exec chmod +x {} \;

# =============================================================================
# 修复 4: SUSFS 补丁兼容性（部分由 Fixed 补丁处理，这里处理剩余的）
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
# 修复 5: 禁用 WERROR（华为内核启用了 -Werror，警告即错误）
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
# 修复 6: netfilter 模块禁用 + 头文件补全
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
           xt_connlimit.h xt_connmark.h xt_conntrack.h xt_cpu.h xt_dccp.h xt_devgroup.h \
           xt_dscp.h xt_ecn.h xt_esp.h xt_helper.h xt_ipcomp.h xt_iprange.h xt_ipvs.h \
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

# 6.4 xt_dscp.h 需要完整定义（uapi/xt_DSCP.h 和 uapi/xt_ecn.h 都引用它）
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

# =============================================================================
# 修复 7: 保留 wlan/bt/fm/gps 驱动编译（不移除，源码完整）
# =============================================================================
# 说明: 华为开源内核包含完整的 wlan/bt/fm/gps 驱动源码
#   - wlan_drv_gen4m: 162 个 .c 文件（WiFi 驱动）
#   - bt: 10 个 .c 文件（蓝牙驱动）
#   - fmradio: 26 个 .c 文件（FM 收音机驱动）
#   - gps_drv: GPS 驱动
# 这些驱动通过 Makefile 的符号链接机制从 vendor/ 目录编译，
# 不需要手动注释掉。如果编译报错，应该修复错误而不是禁用驱动。
# 注意: 之前版本曾错误地注释掉这些驱动，现已恢复。
CONN_MK=drivers/misc/mediatek/connectivity/Makefile
# 不再注释掉 wlan/bt/fm/gps 的编译行，保持华为原始 Makefile 不变

# =============================================================================
# 修复 8: 创建 wmt_exp.h / stp_exp.h 等缺失头文件
# =============================================================================
# 问题: 华为删除了 conninfra 驱动需要的多个头文件:
#         - wmt_exp.h: WMT (Wireless Management Task) 对外接口
#         - stp_exp.h: STP (Serial Transport Protocol) 对外接口
#         - osal_typedef.h: 操作系统抽象层类型定义
#         - wmt_core.h / wmt_dev.h / wmt_task.h 等: stub（桩文件）
#       没有这些头文件，conninfra 驱动编译会报错。
# 修复:
#   8.1 创建 wmt_exp.h（完整接口定义，因为 conninfra.c 引用了里面的函数）
#   8.2 创建 stp_exp.h（同上）
#   8.3 创建 osal_typedef.h（基础类型定义）
#   8.4 为其他头文件创建空 stub（带 #ifndef 保护，防止重复定义）
#   8.5 创建 wmt_stp_stub.c 实现（用空函数实现所有接口）
CONNINFRA_DIR="$VENDOR/conninfra"
CONNINFRA_INC="$CONNINFRA_DIR/include"
COMMON_INC=drivers/misc/mediatek/connectivity/common
mkdir -p "$CONNINFRA_INC" "$COMMON_INC"

# 8.1 wmt_exp.h: WMT 对外接口（完整定义，conninfra.c 会调用这些函数）
cat > "$CONNINFRA_INC/wmt_exp.h" <<'EOF'
#ifndef _WMT_EXP_H_
#define _WMT_EXP_H_
#include <linux/types.h>
typedef int MTK_WCN_BOOL;
#define MTK_WCN_BOOL_TRUE  1
#define MTK_WCN_BOOL_FALSE 0
enum WMTDRV_TYPE {
	WMTDRV_TYPE_STP = 0, WMTDRV_TYPE_BT, WMTDRV_TYPE_FM, WMTDRV_TYPE_GPS,
	WMTDRV_TYPE_WIFI, WMTDRV_TYPE_WMT, WMTDRV_TYPE_SDIO1, WMTDRV_TYPE_SDIO2,
	WMTDRV_TYPE_T, WMTDRV_TYPE_LPBK, WMTDRV_TYPE_GPSL5, WMTDRV_TYPE_MAX
};
enum WMTCHIN { WMTCHIN_CHIPID = 0, WMTCHIN_HWVER, WMTCHIN_ADIE, WMTCHIN_FWVER };
enum WMTDSNS { WMTDSNS_FM_GPS_DISABLE = 0, WMTDSNS_FM_GPS_ENABLE };
#define FM_TASK_INDX   0
#define BT_TASK_INDX   1
#define GPS_TASK_INDX  2
#define WIFI_TASK_INDX 3
#define GPSL5_TASK_INDX 4
struct _MTK_WCN_WLAN_CB_INFO_;
typedef struct _MTK_WCN_WLAN_CB_INFO_ MTK_WCN_WLAN_CB_INFO, *P_MTK_WCN_WLAN_CB_INFO;
MTK_WCN_BOOL mtk_wcn_wmt_func_on(enum WMTDRV_TYPE type);
MTK_WCN_BOOL mtk_wcn_wmt_func_off(enum WMTDRV_TYPE type);
unsigned int mtk_wcn_wmt_ic_info_get(unsigned int idx);
int mtk_wcn_wmt_chipid_query(void);
unsigned int mtk_wcn_wmt_hwver_get(void);
int mtk_wcn_wmt_msgcb_reg(enum WMTDRV_TYPE type, void *cb);
int mtk_wcn_wmt_msgcb_unreg(enum WMTDRV_TYPE type);
int mtk_wcn_wmt_wlan_reg(MTK_WCN_WLAN_CB_INFO *info);
int mtk_wcn_wmt_wlan_unreg(void);
void mtk_wcn_wmt_mpu_lock_aquire(void);
void mtk_wcn_wmt_mpu_lock_release(void);
int mtk_wcn_wmt_co_clock_flag_get(void);
int mtk_wcn_wmt_dsns_ctrl(enum WMTDSNS flag);
void mtk_wcn_wmt_do_reset_only(enum WMTDRV_TYPE type);
void mtk_wcn_wmt_assert(enum WMTDRV_TYPE type, unsigned int arg);
void mtk_wcn_wmt_assert_timeout(enum WMTDRV_TYPE type, unsigned int arg);
void mtk_wcn_wmt_assert_keyword(enum WMTDRV_TYPE type, unsigned int arg);
int32_t mtk_wcn_wmt_wifi_fem_cfg_report(void *pvInfoBuf);
#endif
EOF
# 同时放到 common 目录（华为原始编译路径会找这里）
cp "$CONNINFRA_INC/wmt_exp.h" "$COMMON_INC/wmt_exp.h"

# 8.2 stp_exp.h: STP 对外接口
cat > "$CONNINFRA_INC/stp_exp.h" <<'EOF'
#ifndef _STP_EXP_H_
#define _STP_EXP_H_
#include <linux/types.h>
enum { DBG_TIE_LOW = 0, DBG_TIE_HIGH = 1 };
enum { IDX_GPS_TX = 0, IDX_GPS_RX = 1 };
int mtk_wcn_stp_send_data(const unsigned char *buf, unsigned int len, unsigned char task_idx);
int mtk_wcn_stp_receive_data(unsigned char *buf, unsigned int len, unsigned char task_idx);
int mtk_wcn_stp_register_event_cb(unsigned char task_idx, void *cb);
int mtk_wcn_stp_enable(unsigned int arg);
int mtk_wcn_stp_is_ready(void);
int mtk_wcn_stp_coredump_start_get(void);
void mtk_wcn_stp_debug_gpio_assert(unsigned int idx, unsigned int level);
int mtk_wcn_stp_sdio_wake_up_ctrl(unsigned long ctx);
#endif
EOF
cp "$CONNINFRA_INC/stp_exp.h" "$COMMON_INC/stp_exp.h"

# 8.3 osal_typedef.h: 操作系统抽象层类型定义
cat > "$CONNINFRA_INC/osal_typedef.h" <<'EOF'
#ifndef _OSAL_TYPEDEF_H_
#define _OSAL_TYPEDEF_H_
#include <linux/types.h>
typedef unsigned char  UCHAR,  *PUCHAR;
typedef unsigned char  UINT8,  *PUINT8;
typedef unsigned short UINT16, *PUINT16;
typedef unsigned int   UINT32, *PUINT32;
typedef unsigned long long UINT64, *PUINT64;
typedef signed char    INT8,   *PINT8;
typedef signed short   INT16,  *PINT16;
typedef signed int     INT32,  *PINT32;
typedef unsigned long  ULONG,  *PULONG;
typedef unsigned int   BOOL;
#ifndef TRUE
#define TRUE  1
#endif
#ifndef FALSE
#define FALSE 0
#endif
#endif
EOF
cp "$CONNINFRA_INC/osal_typedef.h" "$COMMON_INC/osal_typedef.h"

# 8.4 为剩余头文件创建空 stub
# 说明: 这些头文件被 conninfra 源码 #include 但华为删了实现，
#        我们用空 stub（只有 #ifndef/#define/#endif）让编译通过，
#        实际功能由下面的 wmt_stp_stub.c 用空函数实现。
for hdr in wmt_core.h wmt_dev.h wmt_task.h conninfra_ext.h \
           mtk_wcn_consys_hw.h mt_clkbuf_ctl.h mtk_6306_gpio.h \
           emi_symbol_hook.h cos_api.h; do
  GUARD=$(echo "$hdr" | tr 'a-z.' 'A-Z_')
  cat > "$CONNINFRA_INC/$hdr" <<EOF
#ifndef _${GUARD}_
#define _${GUARD}_
/* stub - omitted from Honor opensource release */
#endif
EOF
done

# 8.5 wmt_stp_stub.c: 用空函数实现 wmt_exp.h / stp_exp.h 里声明的所有函数
# 说明: conninfra 驱动会调用这些函数，但实际实现被华为删了。
#        我们用空实现（返回 0 或 void）让链接通过，运行时 conninfra 调用这些
#        函数不会真的工作，但不影响内核启动和基本功能。
cat > "$CONNINFRA_DIR/wmt_stp_stub.c" <<'EOF'
#include <linux/types.h>
#include "wmt_exp.h"
#include "stp_exp.h"
MTK_WCN_BOOL mtk_wcn_wmt_func_on(enum WMTDRV_TYPE type) { return MTK_WCN_BOOL_TRUE; }
MTK_WCN_BOOL mtk_wcn_wmt_func_off(enum WMTDRV_TYPE type) { return MTK_WCN_BOOL_TRUE; }
unsigned int mtk_wcn_wmt_ic_info_get(unsigned int idx) { return 0; }
int mtk_wcn_wmt_chipid_query(void) { return 0x6877; }
unsigned int mtk_wcn_wmt_hwver_get(void) { return 0; }
int mtk_wcn_wmt_msgcb_reg(enum WMTDRV_TYPE type, void *cb) { return 0; }
int mtk_wcn_wmt_msgcb_unreg(enum WMTDRV_TYPE type) { return 0; }
int mtk_wcn_wmt_wlan_reg(MTK_WCN_WLAN_CB_INFO *info) { return 0; }
int mtk_wcn_wmt_wlan_unreg(void) { return 0; }
void mtk_wcn_wmt_mpu_lock_aquire(void) {}
void mtk_wcn_wmt_mpu_lock_release(void) {}
int mtk_wcn_wmt_co_clock_flag_get(void) { return 0; }
int mtk_wcn_wmt_dsns_ctrl(enum WMTDSNS flag) { return 1; }
void mtk_wcn_wmt_do_reset_only(enum WMTDRV_TYPE type) {}
void mtk_wcn_wmt_assert(enum WMTDRV_TYPE type, unsigned int arg) {}
void mtk_wcn_wmt_assert_timeout(enum WMTDRV_TYPE type, unsigned int arg) {}
void mtk_wcn_wmt_assert_keyword(enum WMTDRV_TYPE type, unsigned int arg) {}
int32_t mtk_wcn_wmt_wifi_fem_cfg_report(void *pvInfoBuf) { return 0; }
int mtk_wcn_stp_send_data(const unsigned char *buf, unsigned int len, unsigned char task_idx) { return len; }
int mtk_wcn_stp_receive_data(unsigned char *buf, unsigned int len, unsigned char task_idx) { return 0; }
int mtk_wcn_stp_register_event_cb(unsigned char task_idx, void *cb) { return 0; }
int mtk_wcn_stp_enable(unsigned int arg) { return 0; }
int mtk_wcn_stp_is_ready(void) { return 1; }
int mtk_wcn_stp_coredump_start_get(void) { return 0; }
void mtk_wcn_stp_debug_gpio_assert(unsigned int idx, unsigned int level) {}
int mtk_wcn_stp_sdio_wake_up_ctrl(unsigned long ctx) { return 0; }
EOF

# 把 stub.c 加入 conninfra 的编译列表
sed -i '/conninfra_core\.o$/a $(MODULE_NAME)-objs += wmt_stp_stub.o' "$CONNINFRA_DIR/Makefile"

# 给 wlan/adaptor 的 Makefile 加 conninfra 的 include 路径
# 说明: wlan/adaptor 会引用 conninfra 的头文件，需要告诉编译器去哪里找。
WMT_MK="$VENDOR/wlan/adaptor/Makefile"
if [ -f "$WMT_MK" ]; then
  sed -i '/conninfra\/include$/a\ccflags-y += -I$(TOP)/vendor/mediatek/kernel_modules/connectivity/conninfra/drv_init/include\nccflags-y += -I$(TOP)/vendor/mediatek/kernel_modules/connectivity/conninfra/base/include\nccflags-y += -I$(TOP)/vendor/mediatek/kernel_modules/connectivity/conninfra/core/include\nccflags-y += -I$(TOP)/vendor/mediatek/kernel_modules/connectivity/conninfra/conf/include\nccflags-y += -I$(TOP)/vendor/mediatek/kernel_modules/connectivity/conninfra/platform/include' "$WMT_MK"
fi

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

# 9.1 禁用华为安全/检测相关配置（约 20 项）
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
