#!/bin/bash
set -euxo pipefail
cd $GITHUB_WORKSPACE/device_kernel

# 1. 让 srctree 变绝对路径（修复 connectivity 符号链接路径错误）
sed -i 's|srctree := \.\.|srctree := $(abspath ..)|' Makefile

# 2. 把 connectivity 驱动移到 vendor/ 目录
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

# 3. 脚本权限
chmod +x scripts/clang-android.sh
chmod +x arch/arm64/kernel/vdso/gen_vdso_offsets.sh
chmod +x tools/build/cpio
find tools/ -type f -name "*.sh" -exec chmod +x {} \;

# 4. 修复 SUSFS 补丁问题
sed -i 's/ksu_handle_stat(&dfd, &fname, &flag)/ksu_handle_stat(\&dfd, \&fname, \&flags)/' fs/stat.c
sed -i '1i #include <linux/susfs_def.h>' fs/proc/task_mmu.c
# 只在 smap_gather_stats 函数体内把 return 0; 改成 return;（该函数是 void）
python3 -c "
import re
with open('fs/proc/task_mmu.c') as f:
    lines = f.readlines()
in_func = False
found_brace = False
brace_depth = 0
out = []
for line in lines:
    if not in_func and re.search(r'\bsmap_gather_stats\s*\(', line):
        in_func = True
    if in_func:
        if not found_brace and '{' in line:
            found_brace = True
            brace_depth = line.count('{') - line.count('}')
        elif found_brace:
            brace_depth += line.count('{') - line.count('}')
            if 'return 0;' in line:
                line = line.replace('return 0;', 'return;')
            if brace_depth <= 0:
                in_func = False
                found_brace = False
    out.append(line)
with open('fs/proc/task_mmu.c', 'w') as f:
    f.writelines(out)
"

# 5. 禁用 WERROR
find . -name "Makefile" -exec sed -i 's/-Werror/-Wno-error/g' {} +

# 5b. 只编译 conninfra，跳过 wlan/bt/fm/gps
CONN_MK=drivers/misc/mediatek/connectivity/Makefile
sed -i 's|^        obj-y += wmt_chrdev_wifi/|        #obj-y += wmt_chrdev_wifi/|' "$CONN_MK"
sed -i 's|^        obj-y += wlan_drv_gen4m/|        #obj-y += wlan_drv_gen4m/|' "$CONN_MK"
sed -i 's|^        obj-y += bt/|        #obj-y += bt/|' "$CONN_MK"
sed -i 's|^        obj-y += fmradio/|        #obj-y += fmradio/|' "$CONN_MK"
sed -i 's|^         obj-y += gps_drv/|        #obj-y += gps_drv/|' "$CONN_MK"

# 6. 修复 wmt_exp.h / stp_exp.h 缺失
CONNINFRA_DIR="$VENDOR/conninfra"
CONNINFRA_INC="$CONNINFRA_DIR/include"
COMMON_INC=drivers/misc/mediatek/connectivity/common
mkdir -p "$CONNINFRA_INC" "$COMMON_INC"

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
cp "$CONNINFRA_INC/wmt_exp.h" "$COMMON_INC/wmt_exp.h"

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

sed -i '/conninfra_core\.o$/a $(MODULE_NAME)-objs += wmt_stp_stub.o' "$CONNINFRA_DIR/Makefile"

WMT_MK="$VENDOR/wlan/adaptor/Makefile"
if [ -f "$WMT_MK" ]; then
  sed -i '/conninfra\/include$/a\ccflags-y += -I$(TOP)/vendor/mediatek/kernel_modules/connectivity/conninfra/drv_init/include\nccflags-y += -I$(TOP)/vendor/mediatek/kernel_modules/connectivity/conninfra/base/include\nccflags-y += -I$(TOP)/vendor/mediatek/kernel_modules/connectivity/conninfra/core/include\nccflags-y += -I$(TOP)/vendor/mediatek/kernel_modules/connectivity/conninfra/conf/include\nccflags-y += -I$(TOP)/vendor/mediatek/kernel_modules/connectivity/conninfra/platform/include' "$WMT_MK"
fi

# 7. 禁用华为安全检测
DEFCONFIG=arch/arm64/configs/merge_full_k6877v1_64_defconfig
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

echo "[+] All setup done."
