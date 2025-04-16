#!/bin/bash

# Smart BBR Installer & Fixer
# Tested on Ubuntu/Debian/CentOS
# Automatically fixes sysctl.conf, kernel issues, and ensures BBR with fq

# Log file
LOG_FILE="/var/log/bbr_installer.log"
exec 1> >(tee -a "$LOG_FILE") 2>&1
echo "===== BBR Installer Log: $(date) ====="

# Warna untuk output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Fungsi untuk pesan
log_msg() { echo -e "[*] $1"; }
success_msg() { echo -e "${GREEN}[√] $1${NC}"; }
error_msg() { echo -e "${RED}[!] $1${NC}"; }
warn_msg() { echo -e "${YELLOW}[!] $1${NC}"; }

# Fungsi untuk keluar dengan error
error_exit() {
    error_msg "$1"
    echo "Log tersimpan di: $LOG_FILE"
    exit 1
}

# Header
clear
echo "============================================"
echo "  Smart BBR Installer & Fixer"
echo "============================================"

# Periksa root
if [ "$(id -u)" != "0" ]; then
    error_exit "Skrip harus dijalankan sebagai root. Gunakan sudo."
fi

# Fungsi untuk memeriksa status BBR dan qdisc
check_bbr_status() {
    local status=0
    log_msg "Memeriksa status BBR dan qdisc:"
    
    # Check TCP congestion control
    local tcp_cc=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}' 2>/dev/null || echo "unknown")
    if [[ "$tcp_cc" == "bbr" ]]; then
        echo -e "[-] TCP Congestion Control \t: ${GREEN}BBR (Aktif)${NC}"
    else
        echo -e "[-] TCP Congestion Control \t: ${RED}$tcp_cc (BBR Tidak Aktif)${NC}"
        status=1
    fi
    
    # Check Kernel module BBR
    if lsmod | grep -q bbr; then
        echo -e "[-] Kernel Module BBR \t\t: ${GREEN}Loaded${NC}"
    else
        echo -e "[-] Kernel Module BBR \t\t: ${RED}Not Loaded${NC}"
        status=1
    fi
    
    # Check Default qdisc
    local default_qdisc=$(sysctl net.core.default_qdisc | awk '{print $3}' 2>/dev/null || echo "unknown")
    if [[ "$default_qdisc" == "fq" ]]; then
        echo -e "[-] Default Qdisc \t\t: ${GREEN}fq (OK)${NC}"
    else
        echo -e "[-] Default Qdisc \t\t: ${RED}$default_qdisc (Disarankan 'fq')${NC}"
        status=1
    fi
    
    # Check sch_fq module
    if lsmod | grep -q sch_fq; then
        echo -e "[-] Modul sch_fq \t\t: ${GREEN}Loaded${NC}"
    else
        echo -e "[-] Modul sch_fq \t\t: ${RED}Not Loaded${NC}"
        status=1
    fi
    
    return $status
}

# Fungsi untuk mendeteksi distribusi
detect_os() {
    if [ -f /etc/redhat-release ]; then
        OS="centos"
        PKG_MANAGER="yum"
    elif [ -f /etc/lsb-release ] || grep -qi ubuntu /etc/os-release 2>/dev/null; then
        OS="ubuntu"
        PKG_MANAGER="apt-get"
    elif [ -f /etc/debian_version ]; then
        OS="debian"
        PKG_MANAGER="apt-get"
    else
        error_exit "OS tidak didukung. Hanya Ubuntu/Debian/CentOS."
    fi
    log_msg "OS terdeteksi: $OS"
}

# Fungsi untuk memeriksa virtualisasi
check_virtualization() {
    log_msg "Memeriksa jenis virtualisasi..."
    if ! command -v virt-what >/dev/null 2>&1; then
        log_msg "Menginstal virt-what..."
        if [ "$PKG_MANAGER" == "yum" ]; then
            yum install -y virt-what || warn_msg "Gagal menginstal virt-what."
        else
            apt-get update && apt-get install -y virt-what || warn_msg "Gagal menginstal virt-what."
        fi
    fi
    VIRT=$(virt-what 2>/dev/null)
    if [[ "$VIRT" == *"openvz"* ]]; then
        warn_msg "OpenVZ terdeteksi. Kernel dan sysctl mungkin dibatasi oleh penyedia VPS."
        IS_OPENVZ=1
    else
        success_msg "Virtualisasi: ${VIRT:-None/KVM}. Kontrol kernel tersedia."
        IS_OPENVZ=0
    fi
}

# Fungsi untuk memeriksa dan memperbarui kernel
check_and_update_kernel() {
    log_msg "Memeriksa versi kernel..."
    CURRENT_KERNEL=$(uname -r)
    MIN_KERNEL="4.9"
    if [[ "$(echo $CURRENT_KERNEL | cut -d'.' -f1-2)" < "$MIN_KERNEL" ]] || ! lsmod | grep -q sch_fq; then
        warn_msg "Kernel saat ini ($CURRENT_KERNEL) tidak mendukung BBR/fq atau modul sch_fq tidak ada."
        if [ $IS_OPENVZ -eq 1 ]; then
            error_exit "OpenVZ tidak mendukung pembaruan kernel. Hubungi penyedia VPS untuk dukungan BBR/fq."
        fi
        log_msg "Memperbarui kernel..."
        if [ "$OS" == "centos" ]; then
            yum -y install https://www.elrepo.org/elrepo-release-7.el7.elrepo.noarch.rpm || error_exit "Gagal menginstal ELRepo."
            yum --enablerepo=elrepo-kernel -y install kernel-ml || error_exit "Gagal menginstal kernel baru."
            grub2-set-default 0 || error_exit "Gagal mengatur default kernel."
            success_msg "Kernel baru diinstal. Reboot diperlukan."
            NEED_REBOOT=1
        else
            apt-get update || error_exit "Gagal memperbarui paket."
            apt-get install -y linux-generic || apt-get install -y linux-image-5.15.0-73-generic || error_exit "Gagal menginstal kernel baru."
            update-grub || error_exit "Gagal memperbarui GRUB."
            success_msg "Kernel baru diinstal. Reboot diperlukan."
            NEED_REBOOT=1
        fi
    else
        success_msg "Kernel saat ini ($CURRENT_KERNEL) mendukung BBR dan fq."
    fi
}

# Fungsi untuk membersihkan /etc/sysctl.conf
clean_sysctl_conf() {
    log_msg "Memeriksa dan membersihkan /etc/sysctl.conf..."
    SYSCTL_CONF="/etc/sysctl.conf"
    SYSCTL_BACKUP="/etc/sysctl.conf.bak-$(date +%F-%H%M%S)"
    cp "$SYSCTL_CONF" "$SYSCTL_BACKUP" || error_exit "Gagal membuat cadangan /etc/sysctl.conf."
    
    # Hapus baris yang salah format
    sed -i '/bbr fs\/file-max/d' "$SYSCTL_CONF"
    sed -i '/250000 net\/core\/somaxconn/d' "$SYSCTL_CONF"
    sed -i '/1 net\/ipv4\/tcp_tw_reuse/d' "$SYSCTL_CONF"
    sed -i '/3 net\/ipv4\/tcp_mem/d' "$SYSCTL_CONF"
    sed -i '/4096 87380 67108864 net\/ipv4\/tcp_wmem/d' "$SYSCTL_CONF"
    
    # Perbaiki baris dengan format salah
    if grep -q "net.core.wmem_max.*net.core.netdev_max_backlog" "$SYSCTL_CONF"; then
        sed -i 's/net.core.wmem_max = 67108864 net.core.netdev_max_backlog =.*/net.core.wmem_max = 67108864\nnet.core.netdev_max_backlog = 250000/' "$SYSCTL_CONF"
    fi
    
    # Pastikan pengaturan BBR ada
    if ! grep -q "net.core.default_qdisc=fq" "$SYSCTL_CONF"; then
        echo 'net.core.default_qdisc=fq' >> "$SYSCTL_CONF"
    fi
    if ! grep -q "net.ipv4.tcp_congestion_control=bbr" "$SYSCTL_CONF"; then
        echo 'net.ipv4.tcp_congestion_control=bbr' >> "$SYSCTL_CONF"
    fi
    success_msg "/etc/sysctl.conf diperbarui. Cadangan disimpan di $SYSCTL_BACKUP."
}

# Fungsi untuk menerapkan sysctl
apply_sysctl() {
    log_msg "Menerapkan pengaturan sysctl..."
    sysctl -p >/dev/null 2>&1 || {
        warn_msg "Gagal menerapkan beberapa pengaturan sysctl. Mungkin ada entri yang salah di /etc/sysctl.conf."
        return 1
    }
    success_msg "Pengaturan sysctl diterapkan."
    return 0
}

# Fungsi untuk memuat modul
load_modules() {
    log_msg "Memuat modul tcp_bbr dan sch_fq..."
    modprobe tcp_bbr 2>/dev/null || warn_msg "Gagal memuat modul tcp_bbr."
    modprobe sch_fq 2>/dev/null || {
        warn_msg "Gagal memuat modul sch_fq. Kernel mungkin tidak mendukung fq."
        return 1
    }
    success_msg "Modul tcp_bbr dan sch_fq dimuat."
    return 0
}

# Main process
detect_os
check_virtualization
check_bbr_status
if [ $? -eq 0 ]; then
    success_msg "BBR dan fq sudah aktif dan optimal!"
    echo "Log tersimpan di: $LOG_FILE"
    exit 0
fi

warn_msg "BBR atau fq belum aktif/berjalan optimal."
read -p "Lanjutkan untuk memperbaiki dan mengaktifkan BBR? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    log_msg "Proses dibatalkan oleh pengguna."
    exit 0
fi

# Perbaiki sysctl.conf
clean_sysctl_conf

# Muat modul
load_modules || check_and_update_kernel

# Terapkan sysctl
apply_sysctl || {
    warn_msg "Mencoba perbaikan tambahan untuk sysctl..."
    clean_sysctl_conf
    sysctl -p >/dev/null 2>&1 || check_and_update_kernel
}

# Periksa ulang status
check_bbr_status
if [ $? -ne 0 ]; then
    warn_msg "BBR atau fq masih belum optimal."
    if [ $IS_OPENVZ -eq 1 ]; then
        error_exit "OpenVZ mungkin membatasi dukungan fq. Hubungi penyedia VPS."
    fi
    error_exit "Gagal mengaktifkan BBR/fq sepenuhnya. Periksa log di $LOG_FILE."
fi

# Rekomendasi reboot jika perlu
if [ -n "$NEED_REBOOT" ]; then
    echo -e "\n============================================"
    echo "  Proses selesai! Reboot diperlukan."
    echo "  Jalankan skrip ini lagi setelah reboot untuk verifikasi."
    echo "  Log tersimpan di: $LOG_FILE"
    echo "============================================"
    read -p "Reboot sekarang? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        reboot
    fi
else
    echo -e "\n============================================"
    echo "  Proses selesai! BBR dan fq aktif."
    echo "  Log tersimpan di: $LOG_FILE"
    echo "============================================"
fi

exit 0