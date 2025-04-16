#!/bin/bash

# Smart BBR Installer & Fixer (Enhanced)
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
    
    local tcp_cc=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}' 2>/dev/null || echo "unknown")
    if [[ "$tcp_cc" == "bbr" ]]; then
        echo -e "[-] TCP Congestion Control \t: ${GREEN}BBR (Aktif)${NC}"
    else
        echo -e "[-] TCP Congestion Control \t: ${RED}$tcp_cc (BBR Tidak Aktif)${NC}"
        status=1
    fi
    
    if lsmod | grep -q bbr; then
        echo -e "[-] Kernel Module BBR \t\t: ${GREEN}Loaded${NC}"
    else
        echo -e "[-] Kernel Module BBR \t\t: ${RED}Not Loaded${NC}"
        status=1
    fi
    
    local default_qdisc=$(sysctl net.core.default_qdisc | awk '{print $3}' 2>/dev/null || echo "unknown")
    if [[ "$default_qdisc" == "fq" ]]; then
        echo -e "[-] Default Qdisc \t\t: ${GREEN}fq (OK)${NC}"
    else
        echo -e "[-] Default Qdisc \t\t: ${RED}$default_qdisc (Disarankan 'fq')${NC}"
        status=1
    fi
    
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

# Fungsi untuk membersihkan /etc/sysctl.conf secara agresif
clean_sysctl_conf() {
    log_msg "Memeriksa dan membersihkan /etc/sysctl.conf..."
    SYSCTL_CONF="/etc/sysctl.conf"
    SYSCTL_BACKUP="/etc/sysctl.conf.bak-$(date +%F-%H%M%S)"
    cp "$SYSCTL_CONF" "$SYSCTL_BACKUP" || error_exit "Gagal membuat cadangan /etc/sysctl.conf."

    # Buat file sementara untuk menyimpan baris yang valid
    TEMP_FILE=$(mktemp)
    
    # Baca file sysctl.conf baris per baris
    while IFS= read -r line; do
        # Lewati baris kosong atau baris komentar
        if [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]]; then
            echo "$line" >> "$TEMP_FILE"
            continue
        fi

        # Periksa apakah baris memiliki format yang valid (parameter=nilai)
        if [[ "$line" =~ ^[[:space:]]*[a-zA-Z0-9._-]+[[:space:]]*=[[:space:]]*[a-zA-Z0-9[:space:]]+$ ]]; then
            # Baris valid, simpan ke file sementara
            echo "$line" >> "$TEMP_FILE"
        else
            # Baris tidak valid, coba pisahkan jika mengandung beberapa pengaturan
            if [[ "$line" =~ [a-zA-Z0-9._-]+[[:space:]]*=[[:space:]]*[a-zA-Z0-9[:space:]]+ ]]; then
                # Pisahkan baris menjadi beberapa baris berdasarkan pola parameter=nilai
                echo "$line" | grep -o '[a-zA-Z0-9._-]\+[[:space:]]*=[[:space:]]*[a-zA-Z0-9[:space:]]\+' | while IFS= read -r new_line; do
                    echo "$new_line" >> "$TEMP_FILE"
                done
            else
                warn_msg "Baris tidak valid dihapus: $line"
            fi
        fi
    done < "$SYSCTL_CONF"

    # Hapus entri duplikat untuk net.core.default_qdisc dan net.ipv4.tcp_congestion_control
    sed -i '/net.core.default_qdisc/d' "$TEMP_FILE"
    sed -i '/net.ipv4.tcp_congestion_control/d' "$TEMP_FILE"

    # Tambahkan pengaturan BBR di akhir file
    echo "net.core.default_qdisc=fq" >> "$TEMP_FILE"
    echo "net.ipv4.tcp_congestion_control=bbr" >> "$TEMP_FILE"

    # Ganti file sysctl.conf dengan versi yang sudah dibersihkan
    mv "$TEMP_FILE" "$SYSCTL_CONF"
    success_msg "/etc/sysctl.conf diperbarui. Cadangan disimpan di $SYSCTL_BACKUP."
}

# Fungsi untuk menerapkan sysctl dan menangani error
apply_sysctl() {
    log_msg "Menerapkan pengaturan sysctl..."
    SYSCTL_ERROR=$(sysctl -p 2>&1)
    if [ $? -eq 0 ]; then
        success_msg "Pengaturan sysctl diterapkan."
        return 0
    else
        warn_msg "Gagal menerapkan beberapa pengaturan sysctl: $SYSCTL_ERROR"
        # Coba perbaiki dengan membersihkan ulang
        clean_sysctl_conf
        SYSCTL_ERROR=$(sysctl -p 2>&1)
        if [ $? -eq 0 ]; then
            success_msg "Pengaturan sysctl diterapkan setelah perbaikan."
            return 0
        else
            warn_msg "Masih gagal menerapkan sysctl: $SYSCTL_ERROR"
            return 1
        fi
    fi
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
    warn_msg "Mencoba perbaikan terakhir: reset ke konfigurasi minimal..."
    SYSCTL_CONF="/etc/sysctl.conf"
    SYSCTL_BACKUP="/etc/sysctl.conf.bak-$(date +%F-%H%M%S)"
    cp "$SYSCTL_CONF" "$SYSCTL_BACKUP"
    echo "# Minimal sysctl.conf for BBR" > "$SYSCTL_CONF"
    echo "net.core.default_qdisc=fq" >> "$SYSCTL_CONF"
    echo "net.ipv4.tcp_congestion_control=bbr" >> "$SYSCTL_CONF"
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