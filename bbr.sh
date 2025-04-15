#!/bin/bash

# Script Auto Install dan Pendeteksi BBR
# Tested on Ubuntu/Debian/CentOS

clear
echo "============================================"
echo "  BBR Installer & Checker"
echo "============================================"

# Warna untuk output
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Fungsi untuk memeriksa status BBR
check_bbr_status() {
    local status=0
    echo -e "\n[+] Memeriksa status BBR:"
    
    # Check 1: TCP congestion control
    local tcp_cc=$(sysctl net.ipv4.tcp_congestion_control | awk '{print $3}' 2>/dev/null || echo "unknown")
    if [[ "$tcp_cc" == "bbr" ]]; then
        echo -e "[-] TCP Congestion Control \t: ${GREEN}BBR (Aktif)${NC}"
    else
        echo -e "[-] TCP Congestion Control \t: ${RED}$tcp_cc (BBR Tidak Aktif)${NC}"
        status=1
    fi
    
    # Check 2: Kernel module loaded
    if lsmod | grep -q bbr 2>/dev/null; then
        echo -e "[-] Kernel Module BBR \t\t: ${GREEN}Loaded${NC}"
    else
        echo -e "[-] Kernel Module BBR \t\t: ${RED}Not Loaded${NC}"
        status=1
    fi
    
    # Check 3: Default qdisc
    local default_qdisc=$(sysctl net.core.default_qdisc | awk '{print $3}' 2>/dev/null || echo "unknown")
    if [[ "$default_qdisc" == "fq" ]]; then
        echo -e "[-] Default Qdisc \t\t: ${GREEN}fq (OK)${NC}"
    else
        echo -e "[-] Default Qdisc \t\t: ${RED}$default_qdisc (Disarankan 'fq')${NC}"
        status=1
    fi
    
    return $status
}

# Check root
if [ "$(id -u)" != "0" ]; then
   echo -e "${RED}Script ini harus dijalankan sebagai root${NC}" 1>&2
   exit 1
fi

# Deteksi OS
if [ -f /etc/redhat-release ]; then
    OS="centos"
elif [ -f /etc/lsb-release ] || grep -qi ubuntu /etc/os-release 2>/dev/null; then
    OS="ubuntu"
elif [ -f /etc/debian_version ]; then
    OS="debian"
else
    echo -e "${RED}OS tidak didukung. Script ini hanya untuk Ubuntu/Debian/CentOS${NC}"
    exit 1
fi

# Periksa versi kernel
CURRENT_KERNEL=$(uname -r)
MIN_KERNEL="4.9"
KERNEL_UPDATE_NEEDED=0
if [[ "$(echo $CURRENT_KERNEL | cut -d'.' -f1-2)" < "$MIN_KERNEL" ]]; then
    KERNEL_UPDATE_NEEDED=1
fi

# Periksa status BBR pertama kali
check_bbr_status
if [ $? -eq 0 ] && [ $KERNEL_UPDATE_NEEDED -eq 0 ]; then
    echo -e "\n${GREEN}[√] BBR sudah aktif!${NC}"
    exit 0
fi

echo -e "\n${RED}[!] BBR belum aktif atau tidak berjalan optimal${NC}"
if [ $KERNEL_UPDATE_NEEDED -eq 1 ]; then
    echo -e "${RED}[!] Kernel saat ini ($CURRENT_KERNEL) di bawah 4.9, perlu pembaruan${NC}"
fi
read -p "Apakah Anda ingin mengaktifkan BBR? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    exit 0
fi

# Proses instalasi kernel jika diperlukan
if [ $KERNEL_UPDATE_NEEDED -eq 1 ]; then
    echo -e "\n[+] Memperbarui sistem dan menginstal kernel terbaru..."
    if [ "$OS" == "centos" ]; then
        yum -y update || { echo -e "${RED}Gagal memperbarui sistem${NC}"; exit 1; }
        yum -y install https://www.elrepo.org/elrepo-release-7.el7.elrepo.noarch.rpm || { echo -e "${RED}Gagal menginstal ELRepo${NC}"; exit 1; }
        yum --enablerepo=elrepo-kernel -y install kernel-ml || { echo -e "${RED}Gagal menginstal kernel baru${NC}"; exit 1; }
        grub2-set-default 0 || { echo -e "${RED}Gagal mengatur default kernel${NC}"; exit 1; }
    elif [ "$OS" == "ubuntu" ] || [ "$OS" == "debian" ]; then
        apt-get -y update || { echo -e "${RED}Gagal memperbarui sistem${NC}"; exit 1; }
        apt-get -y install --install-recommends linux-generic || { echo -e "${RED}Gagal menginstal kernel baru${NC}"; exit 1; }
    fi
fi

# Aktifkan BBR
echo -e "\n[+] Mengaktifkan BBR..."
if ! grep -q "net.core.default_qdisc=fq" /etc/sysctl.conf; then
    echo 'net.core.default_qdisc=fq' >> /etc/sysctl.conf || { echo -e "${RED}Gagal mengatur qdisc${NC}"; exit 1; }
fi
if ! grep -q "net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf; then
    echo 'net.ipv4.tcp_congestion_control=bbr' >> /etc/sysctl.conf || { echo -e "${RED}Gagal mengatur BBR${NC}"; exit 1; }
fi

# Terapkan perubahan
sysctl -p >/dev/null || { echo -e "${RED}Gagal menerapkan pengaturan sysctl${NC}"; exit 1; }

# Periksa status BBR setelah aktivasi
echo -e "\n[+] Memeriksa hasil aktivasi BBR..."
check_bbr_status
if [ $? -ne 0 ]; then
    echo -e "\n${RED}[!] BBR gagal diaktifkan sepenuhnya. Mungkin perlu reboot.${NC}"
fi

# Rekomendasi reboot
echo -e "\n============================================"
echo "  Proses selesai!"
if [ $KERNEL_UPDATE_NEEDED -eq 1 ]; then
    echo "  Disarankan untuk reboot server"
    echo "  Setelah reboot, jalankan script ini lagi"
    echo "  untuk memverifikasi BBR aktif"
fi
echo "============================================"

read -p "Reboot sekarang? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    reboot
fi
