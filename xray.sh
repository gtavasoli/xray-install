#!/usr/bin/env bash

# Colors
Color_Off='\033[0m'
Black='\033[0;30m'
Red='\033[0;31m'
Green='\033[0;32m'
Yellow='\033[0;33m'
Blue='\033[0;34m'
Purple='\033[0;35m'
Cyan='\033[0;36m'
White='\033[0;37m'

# Constants
XRAY_CONFIG_DIRECTORY="/usr/local/etc/xray"
XRAY_CONFIG_FILE="/usr/local/etc/xray/config.json"

# Variables 
github_branch="main"
users_count_file="/usr/local/etc/xray/users_count.txt"
users_number_in_config_file="/usr/local/etc/xray/users_number_in_config.txt"
access_log_path="/var/log/xray/access.log"
users_expiry_date_file="/usr/local/etc/xray/users_expiry_date.txt"
proto_file="/usr/local/etc/xray/proto.txt"
backup_dir="/root/xray_backup"
website_dir="/var/www/html" 
cert_group="nobody"
random_num=$((RANDOM % 12 + 4))
nginx_conf="/etc/nginx/sites-available/default"
go_version="1.22.2"


WS_PATH="/$(head -n 10 /dev/urandom | md5sum | head -c ${random_num})"
PASSWORD="$(head -n 10 /dev/urandom | md5sum | head -c 18)"

OK="${Green}[OK]"
ERROR="${Red}[ERROR]"
INFO="${Yellow}[INFO]"

SLEEP="sleep 0.2"

#print OK
function print_ok() {
    echo -e "${OK} $1 ${Color_Off}"
}

#print ERROR
function print_error() {
    echo -e "${ERROR} $1 ${Color_Off}"
}

#print INFO
function print_info() {
    echo -e "${INFO} $1 ${Color_Off}"
}

function installit() {
    apt install -y $*
}

function judge() {
    if [[ 0 -eq $? ]]; then
        print_ok "$1 Finished"
        $SLEEP
    else
        print_error "$1 Failed"
        exit 1
    fi
}

# Check the shell
function check_bash() {
    is_BASH=$(readlink /proc/$$/exe | grep -q "bash")
    if [[ $is_BASH -ne "bash" ]]; then
        print_error "This installer needs to be run with bash, not sh."
        exit
    fi
}

# Check root
function check_root() {
    if [[ "$EUID" -ne 0 ]]; then
        print_error "This installer needs to be run with superuser privileges. Login as root user and run the script again!"
        exit
    else 
        print_ok "Root user checked!" ; $SLEEP
    fi
}

# Check OS
function check_os() {
    if grep -qs "ubuntu" /etc/os-release; then
        os="ubuntu"
        os_version=$(grep 'VERSION_ID' /etc/os-release | cut -d '"' -f 2 | tr -d '.')
        print_ok "Ubuntu detected!"
    elif [[ -e /etc/debian_version ]]; then
        os="debian"
        os_version=$(cat /etc/debian_version | cut -d '.' -f 1)
        print_ok "Debian detected!"
    else
        print_error "This installer seems to be running on an unsupported distribution.
        Supported distros are ${Yellow}Debian${Color_Off} and ${Yellow}Ubuntu${Color_Off}."
        exit
    fi
    if [[ "$os" == "ubuntu" && "$os_version" -lt 2004 ]]; then
        print_error "${Yellow}Ubuntu 20.04${Color_Off} or higher is required to use this installer.
        This version of Ubuntu is too old and unsupported."
        exit
    elif [[ "$os" == "debian" && "$os_version" -lt 10 ]]; then
        print_error "${Yellow}Debian 11${Color_Off} or higher is required to use this installer.
        This version of debian is too old and unsupported."
        exit
    fi
}

function disable_firewalls() {
    is_firewalld=$(systemctl is-actice --quiet firewalld)
    is_nftables=$(systemctl is-actice --quiet nftables)
    is_ufw=$(systemctl is-actice --quiet ufw)

    if ${is_nftables}; then
        systemctl stop nftables
        systemctl disable nftables
    fi 

    if ${is_ufw}; then
        systemctl stop ufw
        systemctl disable ufw
    fi

    if ${is_firewalld}; then
        systemctl stop firewalld
        systemctl disable firewalld
    fi
}


function install_nginx() {
    installit nginx
}


function install_deps() {
    installit lsof tar cron htop unzip curl \
        libpcre3 libpcre3-dev zlib1g-dev openssl \
        libssl-dev qrencode jq
    judge "Install dependencies"

    touch /var/spool/cron/crontabs/root && chmod 600 /var/spool/cron/crontabs/root
    systemctl start cron && systemctl enable cron
    judge "crontab autostart"

    if [[ ! -e "/usr/local/bin" ]]; then
        mkdir /usr/local/bin >/dev/null 2>&1
    fi
}


function basic_optimization() {
    sed -i '/^\*\ *soft\ *nofile\ *[[:digit:]]*/d' /etc/security/limits.conf
    sed -i '/^\*\ *hard\ *nofile\ *[[:digit:]]*/d' /etc/security/limits.conf
    echo '* soft nofile 65536' >>/etc/security/limits.conf
    echo '* hard nofile 65536' >>/etc/security/limits.conf
}


function ip_check() {
    local_ipv4=$(curl -s4m8 https://icanhazip.com)
    local_ipv6=$(curl -s6m8 https://icanhazip.com)

    if [[ -z ${local_ipv4} && -n ${local_ipv6} ]]; then
        print_ok "Pure IPv6 server"
        SERVER_IP=$(curl -s6m8 https://icanhazip.com)
    else
        print_ok "Server has IPv4"
        SERVER_IP=$(curl -s4m8 https://icanhazip.com)
    fi
}


function cloudflare_dns() {
    ip_check
    if [[ -z ${local_ipv4} && -n ${local_ipv6} ]]; then
        echo "nameserver 2606:4700:4700::1111" > /etc/resolv.conf
        echo "nameserver 2606:4700:4700::1001" >> /etc/resolv.conf
        judge "add IPv6 DNS to resolv.conf"
    else
        echo "nameserver 1.1.1.1" > /etc/resolv.conf
        echo "nameserver 1.0.0.1" >> /etc/resolv.conf
        judge "add IPv4 DNS to resolv.conf"
    fi
}

function domain_check() {
    read -rp "Please enter your domain name information (example: www.google.com):" domain
    echo -e "${domain}" >/usr/local/domain.txt

    domain_ip=$(ping -c 1 ${domain} | grep -m 1 -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}')
    print_ok "Getting domain IP address information, please be wait..."

    local_ipv4=$(curl -s4m8 https://icanhazip.com)
    local_ipv6=$(curl -s6m8 https://icanhazip.com)

    if [[ -z ${local_ipv4} && -n ${local_ipv6} ]]; then
        # Pure IPv6 VPS, automatically add DNS64 server for acme.sh to apply for certificate
        echo -e nameserver 2606:4700:4700::1111 > /etc/resolv.conf
        print_ok "Recognized VPS as IPv6 Only, automatically add DNS64 server"
    fi
    echo -e "DNS-resolved IP address of the domain name: ${domain_ip}"
    echo -e "Local public network IPv4 address ${local_ipv4}"
    echo -e "Local public network IPv6 address ${local_ipv6}"
    sleep 2
    if [[ ${domain_ip} == ${local_ipv4} ]]; then
        print_ok "The DNS-resolved IP address of the domain name matches the native IPv4 address"
        sleep 2
    elif [[ ${domain_ip} == ${local_ipv6} ]]; then
        print_ok "The DNS-resolved IP address of the domain name matches the native IPv6 address"
        sleep 2
    else
        print_error "Please make sure that the correct A/AAAA records are added to the domain name, otherwise xray will not work properly"
        print_error "The IP address of the domain name resolved through DNS does not match the native IPv4/IPv6 address, 
        do you want to continue the installation? (y/n)" && read -r install
        case $install in
        [yY][eE][sS] | [yY])
          print_ok "Continue Installation"
          sleep 2
          ;;
        *)
          print_error "Installation terminated"
          exit 2
          ;;
        esac
    fi
}

function port_exist_check() {
    if [[ 0 -eq $(lsof -i:"$1" | grep -i -c "listen") ]]; then
        print_ok "$1 Port is not in use"
        sleep 1
    else
        print_error "It is detected that port $1 is occupied, the following is the occupancy information of port $1"
        lsof -i:"$1"
        print_error "After 5s, it will try to kill the occupied process automatically"
        sleep 5
        lsof -i:"$1" | awk '{print $2}' | grep -v "PID" | xargs kill -9
        print_ok "Kill Finished"
        sleep 1
    fi
}

function xray_tmp_config_file_check_and_use() {
    if [[ -s ${XRAY_CONFIG_DIRECTORY}/config_tmp.json ]]; then
        mv -f ${XRAY_CONFIG_DIRECTORY}/config_tmp.json ${XRAY_CONFIG_DIRECTORY}/config.json
    else
        print_error "can't modify xray config file!"
        exit 1
    fi
    touch ${XRAY_CONFIG_DIRECTORY}/config_tmp.json
}

function restart_nginx(){
    systemctl enable --now nginx
    judge "Nginx start"
    systemctl restart nginx
    judge "Nginx restart"
}

function configure_nginx_reverse_proxy_tls() {
    rm -rf ${nginx_conf} && wget -O ${nginx_conf} https://raw.githubusercontent.com/thehxdev/xray-examples/main/nginx/nginx_reverse_proxy_tls.conf
    judge "Nginx config Download"

    sed -i "s/YOUR_DOMAIN/${domain}/g" ${nginx_conf}
    judge "Nginx config add domain"
}

function configure_nginx_reverse_proxy_notls() {
    rm -rf ${nginx_conf} && wget -O ${nginx_conf} https://raw.githubusercontent.com/thehxdev/xray-examples/main/nginx/nginx_reverse_proxy_notls.conf
    judge "Nginx config Download"

    sed -i "s/YOUR_DOMAIN/${local_ipv4}/g" ${nginx_conf}
    judge "Nginx config add ip"

    restart_nginx
}

function add_wsPath_to_nginx() {
    sed -i "s.wsPATH.${WS_PATH}.g" ${nginx_conf}
    judge "Nginx Websocket Path modification"
}

function setup_fake_website() {
    wget https://github.com/arcdetri/sample-blog/archive/master.zip
    judge "Download sample-blog website"

    unzip master.zip
    judge "unzip sample-blog website"

    cp -rf sample-blog-master/html/* /var/www/html/
    judge "copy sample-blog website to /var/www/html"

    rm -rf master.zip sample-blog-master
}

function send_go_and_gost() {
    read -rp "Domestic relay IP:" domestic_relay_ip
    cd /root/
    wget https://go.dev/dl/go${go_version}.linux-amd64.tar.gz
    judge "Golang Download"
    scp ./go${go_version}.linux-amd64.tar.gz root@${domestic_relay_ip}:/root/
    judge "send Golang to domestic relay"

    wget https://github.com/ginuerzh/gost/releases/download/v2.11.4/gost-linux-amd64-2.11.4.gz
    judge "Gost Download"
    scp ./gost-linux-amd64-2.11.4.gz root@${domestic_relay_ip}:/root/
    judge "send Gost to domestic relay"
}

function install_gost_and_go() {
    if [[ -e "/usr/local/go" ]]; then
        rm -rf /usr/local/go 
        if [[ -e "/root/go${go_version}.linux-amd64.tar.gz" ]]; then
            tar -C /usr/local -xzf go${go_version}.linux-amd64.tar.gz
            judge "install Golang"
        else
            print_error "Can't find golang archive file"
            exit 1
        fi
    else
        print_ok "Golang Already installed"
    fi

    if [[ ! -e "/usr/local/bin/gost" ]] ;then 
        if [[ -e "gost-linux-amd64-2.11.4.gz" ]]; then
            gunzip gost-linux-amd64-2.11.4.gz
            judge "Gost extract"
            mv gost-linux-amd64-2.11.4 /usr/local/bin/gost
            judge "move Gost"
            chmod +x /usr/local/bin/gost
            judge "Make Gost executable"
        else
            print_error "Can't find golang archive file"
            exit 1
        fi
    else
        print_ok "Gost is installed"
    fi
}

function configure_gost_and_go() {
    install_gost_and_go

    read -rp "Foreign server IP:" foreign_server_ip
    read -rp "Foreign server Port:" foreign_server_port
    read -rp "Listening Port:" listening_port

    cat << EOF > /usr/lib/systemd/system/gost.service
[Unit]
Description=GO Simple Tunnel
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/gost -L=tcp://:${listening_port}/$foreign_server_ip:${foreign_server_port}

[Install]
WantedBy=multi-user.target

EOF

    judge "adding systemd unit for gost"

    systemctl enable --now gost.service
    judge "gost service start"

    echo -e "${Blue}Listening Port = ${Green}${listening_port}${Color_Off}"
    echo -e "${Blue}Forwarding incoming traffic to ${Green}${foreign_server_ip}:${foreign_server_port}${Color_Off}"
}


function xray_install() {
    print_ok "Installing Xray"
    curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh | bash -s -- install
    judge "Xray Installation"

    groupadd nobody
    gpasswd -a nobody nobody
    judge "add nobody user to nobody group"
}


function modify_port() {
    read -rp "Please enter the port number (default: 8080): " PORT
    [ -z "$PORT" ] && PORT="8080"
    if [[ $PORT -le 0 ]] || [[ $PORT -gt 65535 ]]; then
        print_error "Port must be in range of 0-65535"
        exit 1
    fi
    port_exist_check $PORT
    cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq 'setpath(["inbounds",0,"port"];'${PORT}')' >${XRAY_CONFIG_DIRECTORY}/config_tmp.json
    xray_tmp_config_file_check_and_use
    judge "Xray port modification"
}


function modify_UUID() {
    [ -z "$UUID" ] && UUID=$(cat /proc/sys/kernel/random/uuid)
    cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq 'setpath(["inbounds",0,"settings","clients",0,"id"];"'${UUID}'")' >${XRAY_CONFIG_DIRECTORY}/config_tmp.json
    judge "modify Xray UUID"
    xray_tmp_config_file_check_and_use
    judge "change tmp file to main file"
}

function modify_UUID_ws() {
    cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq 'setpath(["inbounds",1,"settings","clients",0,"id"];"'${UUID}'")' >${XRAY_CONFIG_DIRECTORY}/config_tmp.json
    judge "modify Xray ws UUID"
    xray_tmp_config_file_check_and_use
    judge "change tmp file to main file"
}


function modify_ws() {
    cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq 'setpath(["inbounds",0,"streamSettings","wsSettings","path"];"'${WS_PATH}'")' >${XRAY_CONFIG_DIRECTORY}/config_tmp.json
    judge "modify Xray ws"
    xray_tmp_config_file_check_and_use
    judge "change tmp file to main file"
}

function modify_tls() {
    cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq 'setpath(["inbounds",0,"streamSettings","tlsSettings","certificates",0,"certificateFile"];"'${certFile}'")' >${XRAY_CONFIG_DIRECTORY}/config_tmp.json
    judge "modify Xray TLS Cert File"
    xray_tmp_config_file_check_and_use
    judge "change tmp file to main file"
    cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq 'setpath(["inbounds",0,"streamSettings","tlsSettings","certificates",0,"keyFile"];"'${keyFile}'")' >${XRAY_CONFIG_DIRECTORY}/config_tmp.json
    judge "modify Xray TLS Key File"
    xray_tmp_config_file_check_and_use
    judge "change tmp file to main file"
}

function modify_PASSWORD() {
    cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq 'setpath(["inbounds",0,"settings","clients",0,"password"];"'${PASSWORD}'")' >${XRAY_CONFIG_DIRECTORY}/config_tmp.json
    judge "modify Xray Trojan Password"
    xray_tmp_config_file_check_and_use
    judge "change tmp file to main file"
}

function configure_certbot() {
    mkdir /ssl >/dev/null 2>&1
    installit certbot python3-certbot
    judge "certbot python3-certbot Installation"
    certbot certonly --standalone --preferred-challenges http --register-unsafely-without-email -d $domain
    judge "certbot ssl certification"

    cp /etc/letsencrypt/archive/$domain/fullchain1.pem /ssl/xray.crt
    judge "copy cert file"
    cp /etc/letsencrypt/archive/$domain/privkey1.pem /ssl/xray.key
    judge "copy key file"

    chown -R nobody.$cert_group /ssl/*
    certFile="/ssl/xray.crt"
    keyFile="/ssl/xray.key"
}

function renew_certbot() {
    certbot renew --dry-run
    judge "SSL renew"
}

function xray_uninstall() {
    print_info "This Option will remove Xray-Core and all of it's configurations. Are you sure? [y/n]"
    read -r uninstall_xray
    case $uninstall_xray in
    [yY][eE][sS] | [yY])
        curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh | bash -s -- remove --purge
        rm -rf $website_dir/*

        if ! command -v nginx; then
            print_info "Nginx is not installed"
        else
            print_info "Do you want to Disable (Not uninstall) Nginx (This will free 443 or 80 port) [y/n]?"
            read -r disable_nginx
            case $disable_nginx in
            [yY][eE][sS] | [yY])
                systemctl disable --now nginx.service
                ;;
            *) ;;
            esac

            print_info "Do you want to uninstall Nginx [y/n]?"
            read -r uninstall_nginx
            case $uninstall_nginx in
            [yY][eE][sS] | [yY])
                rm -rf /var/www/html/*
                systemctl disable --now nginx.service
                apt purge nginx -y
                ;;
            *) ;;
            esac
        fi

        print_info "Uninstall certbot (This will remove SSL Cert files too)? [y/n]?"
        read -r uninstall_certbot
        case $uninstall_certbot in
        [yY][eE][sS] | [yY])
            apt purge certbot python3-certbot -y
            rm -rf /etc/letsencrypt/
            rm -rf /var/log/letsencrypt/
            rm -rf /etc/systemd/system/*certbot*
            rm -rf /ssl/
            ;;
        *) ;;
        esac

        print_ok "Uninstall complete"
        exit 0
        ;;
    *) ;;
    esac
}

function restart_all() {
    systemctl restart nginx
    judge "Nginx start"
    systemctl restart xray
    judge "Xray start"
}

function restart_xray() {
    systemctl restart xray
    judge "Xray start"
}

function bbr_boost() {
    wget -N --no-check-certificate https://github.com/teddysun/across/raw/master/bbr.sh && chmod +x bbr.sh && bash bbr.sh
}

function configure_user_management() {
    echo -e "checking..."
    if [[ ! -e "${XRAY_CONFIG_FILE}" ]]; then
        print_error "can't find xray config. Seems like you don't installed xray"
        exit 1
    else
        print_ok "xray is installed"
    fi

    if grep -q -E -o "[1-9]{1,3}@" ${XRAY_CONFIG_FILE} ; then
        print_ok "admin user found"
    else
        cp ${XRAY_CONFIG_FILE} ${XRAY_CONFIG_DIRECTORY}/config.json.bak
        judge "make backup file from config.json"
        cat ${XRAY_CONFIG_FILE} | jq 'setpath(["inbounds",0,"settings","clients",0,"email"];"1@admin")' >${XRAY_CONFIG_DIRECTORY}/config_tmp.json
        judge "initialize first user"
        xray_tmp_config_file_check_and_use
    fi

    if [[ ! -e "${users_count_file}" && ! -e "${users_number_in_config_file}" ]]; then
        print_info "users_count.txt not found! Creating one..."
        touch ${users_count_file}
        judge "create user count file"
        echo -e "1" > ${users_count_file}
        touch ${users_number_in_config_file}
        judge "create user number file"
        echo -e "1" > ${users_number_in_config_file}
    else
        print_ok "rquired files exist"
    fi
}


function user_counter() {
    users_count=$(cat ${users_count_file})

    echo -e "\nCurrent Users Count = ${users_count}"
    echo -e "Old Users:"
    for ((i = 0; i < ${users_count}; i++)); do
        name=$(cat ${XRAY_CONFIG_FILE} | jq .inbounds[0].settings.clients[${i}].email | tr -d '"')
        current_user_number=$(cat ${XRAY_CONFIG_FILE} | jq .inbounds[0].settings.clients[${i}].email | grep -Eo "[1-9]{1,3}")
        echo -e "  ${i}) $name"
    done
    echo -e ""
}

# ========== VLESS ========== #

# VLESS + WS + TLS
function vless_ws_tls_link_gen() {
    read -rp "Choose config name: " config_name
    UUID=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].settings.clients[0].id | tr -d '"')
    PORT=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].port)
    WEBSOCKET_PATH=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].streamSettings.wsSettings.path | tr -d '"')
    CONFIG_DOMAIN=$(cat /usr/local/domain.txt)
    SERVER_IP=$(curl -s4m8 https://icanhazip.com)
    # server_link=$(echo -neE "$UUID@$SERVER_IP:$PORT?sni=$CONFIG_DOMAIN&security=tls&type=ws&path=$WEBSOCKET_PATH#$config_name")
    server_link=$(echo -neE "$UUID@$SERVER_IP:$PORT?sni=$CONFIG_DOMAIN&security=tls&encryption=none&type=ws&path=$WEBSOCKET_PATH&host=$CONFIG_DOMAIN#$config_name")

    qrencode -t ansiutf8 -l L vless://${server_link}
    echo -ne "${Green}VLESS Link: ${Yellow}vless://$server_link${Color_Off}\n"
}

function users_vless_ws_tls_link_gen() {
    user_counter
    read -rp "Choose User: " user_number
    read -rp "Choose config name: " config_name
    UUID=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].settings.clients[${user_number}].id | tr -d '"')
    PORT=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].port)
    WEBSOCKET_PATH=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].streamSettings.wsSettings.path | tr -d '"')
    CONFIG_DOMAIN=$(cat /usr/local/domain.txt)
    SERVER_IP=$(curl -s4m8 https://icanhazip.com)
    # server_link=$(echo -neE "$UUID@$SERVER_IP:$PORT?sni=$CONFIG_DOMAIN&security=tls&type=ws&path=$WEBSOCKET_PATH#$config_name")
    server_link=$(echo -neE "$UUID@$SERVER_IP:$PORT?sni=$CONFIG_DOMAIN&security=tls&encryption=none&type=ws&path=$WEBSOCKET_PATH&host=$CONFIG_DOMAIN#$config_name")

    qrencode -t ansiutf8 -l L vless://${server_link}
    echo -ne "${Green}VLESS Link: ${Yellow}vless://$server_link${Color_Off}\n"
}

function vless_ws_tls() {
    check_bash
    check_root
    check_os
    disable_firewalls
    install_deps
    basic_optimization
    ip_check
    domain_check
    xray_install
    configure_certbot
    wget -O ${XRAY_CONFIG_DIRECTORY}/config.json https://raw.githubusercontent.com/thehxdev/xray-examples/main/VLESS-Websocket-TLS-s/server_config.json
    judge "Download configuration"
    modify_port
    modify_UUID
    modify_ws
    modify_tls
    restart_xray
    vless_ws_tls_link_gen
    CONFIG_PROTO="VlessWsTls"
    save_protocol
}

# VLESS + TCP + TLS
function vless_tcp_tls_link_gen() {
    read -rp "Choose config name: " config_name
    UUID=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].settings.clients[0].id | tr -d '"')
    PORT=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].port)
    CONFIG_DOMAIN=$(cat /usr/local/domain.txt)
    server_link=$(echo -neE "$UUID@$SERVER_IP:$PORT?sni=$CONFIG_DOMAIN&security=tls&type=tcp#$config_name")

    qrencode -t ansiutf8 -l L vless://${server_link}
    echo -ne "${Green}VLess Link: ${Yellow}vless://$server_link${Color_Off}\n"
}

function users_vless_tcp_tls_link_gen() {
    user_counter
    read -rp "Choose User: " user_number
    read -rp "Choose config name: " config_name
    UUID=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].settings.clients[${user_number}].id | tr -d '"')
    PORT=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].port)
    CONFIG_DOMAIN=$(cat /usr/local/domain.txt)
    server_link=$(echo -neE "$UUID@$SERVER_IP:$PORT?sni=$CONFIG_DOMAIN&security=tls&type=tcp#$config_name")

    qrencode -t ansiutf8 -l L vless://${server_link}
    echo -ne "${Green}VLESS Link: ${Yellow}vless://$server_link${Color_Off}\n"
}

function vless_tcp_tls() {
    check_bash
    check_root
    check_os
    disable_firewalls
    install_deps
    basic_optimization
    ip_check
    domain_check
    xray_install
    configure_certbot
    wget -O ${XRAY_CONFIG_DIRECTORY}/config.json https://raw.githubusercontent.com/thehxdev/xray-examples/main/VLESS-TCP-TLS-Minimal-s/config_server.json
    judge "Download configuration"
    modify_port
    modify_UUID
    modify_tls
    restart_xray
    vless_tcp_tls_link_gen
    CONFIG_PROTO="VlessTcpTls"
    save_protocol
}


# ========== VMESS ========== #

# VMESS + WS 
function vmess_ws_link_gen() {
    read -rp "Choose config name: " config_name
    UUID=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].settings.clients[0].id | tr -d '"')
    PORT=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].port)
    WEBSOCKET_PATH=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].streamSettings.wsSettings.path | tr -d '"')
    SERVER_IP=$(curl -s4m8 https://icanhazip.com)
    server_link=$(echo -neE "{\"add\": \"$SERVER_IP\",\"aid\": \"0\",\"host\": \"\",\"id\": \"$UUID\",\"net\": \"ws\",\"path\": \"$WEBSOCKET_PATH\",\"port\": \"$PORT\",\"ps\": \"$config_name\",\"scy\": \"chacha20-poly1305\",\"sni\": \"\",\"tls\": \"\",\"type\": \"\",\"v\": \"2\"}" | base64 | tr -d '\n')

    qrencode -t ansiutf8 -l L vmess://${server_link}
    echo -ne "${Green}VMESS Link: ${Yellow}vmess://$server_link${Color_Off}\n"
}

function users_vmess_ws_link_gen() {
    user_counter
    read -rp "Choose User: " user_number
    read -rp "Choose config name: " config_name
    UUID=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].settings.clients[${user_number}].id | tr -d '"')
    PORT=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].port)
    WEBSOCKET_PATH=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].streamSettings.wsSettings.path | tr -d '"')
    SERVER_IP=$(curl -s4m8 https://icanhazip.com)
    server_link=$(echo -neE "{\"add\": \"$SERVER_IP\",\"aid\": \"0\",\"host\": \"\",\"id\": \"$UUID\",\"net\": \"ws\",\"path\": \"$WEBSOCKET_PATH\",\"port\": \"$PORT\",\"ps\": \"$config_name\",\"scy\": \"chacha20-poly1305\",\"sni\": \"\",\"tls\": \"\",\"type\": \"\",\"v\": \"2\"}" | base64 | tr -d '\n')

    qrencode -t ansiutf8 -l L vmess://${server_link}
    echo -ne "${Green}VMESS Link: ${Yellow}vmess://$server_link${Color_Off}\n"
}

function vmess_ws() {
    check_bash
    check_root
    check_os
    disable_firewalls
    install_deps
    basic_optimization
    ip_check
    xray_install
    wget -O ${XRAY_CONFIG_DIRECTORY}/config.json https://raw.githubusercontent.com/thehxdev/xray-examples/main/VMess-Websocket-s/config_server.json
    judge "Download configuration"
    modify_port
    modify_UUID
    modify_ws
    restart_xray
    vmess_ws_link_gen
    CONFIG_PROTO="VmessWs"
    save_protocol
}


# ==== VMESS + WS + TLS ====
function vmess_ws_tls_link_gen() {
    read -rp "Choose config name: " config_name
    UUID=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].settings.clients[0].id | tr -d '"')
    PORT=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].port)
    WEBSOCKET_PATH=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].streamSettings.wsSettings.path | tr -d '"')
    CONFIG_DOMAIN=$(cat /usr/local/domain.txt)
    SERVER_IP=$(curl -s4m8 https://icanhazip.com)
    # server_link=$(echo -neE "{\"add\": \"$SERVER_IP\",\"aid\": \"0\",\"host\": \"\",\"id\": \"$UUID\",\"net\": \"ws\",\"path\": \"$WEBSOCKET_PATH\",\"port\": \"$PORT\",\"ps\": \"$config_name\",\"scy\": \"chacha20-poly1305\",\"sni\": \"$CONFIG_DOMAIN\",\"tls\": \"tls\",\"type\": \"\",\"v\": \"2\"}" | base64 | tr -d '\n')
    server_link=$(echo -neE "{\"add\": \"$SERVER_IP\",\"aid\": \"0\",\"host\": \"$CONFIG_DOMAIN\",\"id\": \"$UUID\",\"net\": \"ws\",\"path\": \"$WEBSOCKET_PATH\",\"port\": \"$PORT\",\"ps\": \"$config_name\",\"scy\": \"chacha20-poly1305\",\"sni\": \"$CONFIG_DOMAIN\",\"tls\": \"tls\",\"type\": \"\",\"v\": \"2\"}" | base64 | tr -d '\n')

    qrencode -t ansiutf8 -l L vmess://${server_link}
    echo -ne "${Green}VMESS Link: ${Yellow}vmess://$server_link${Color_Off}\n"
}

function users_vmess_ws_tls_link_gen() {
    user_counter
    read -rp "Choose User: " user_number
    read -rp "Choose config name: " config_name
    UUID=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].settings.clients[${user_number}].id | tr -d '"')
    PORT=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].port)
    WEBSOCKET_PATH=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].streamSettings.wsSettings.path | tr -d '"')
    CONFIG_DOMAIN=$(cat /usr/local/domain.txt)
    SERVER_IP=$(curl -s4m8 https://icanhazip.com)
    # server_link=$(echo -neE "{\"add\": \"$SERVER_IP\",\"aid\": \"0\",\"host\": \"\",\"id\": \"$UUID\",\"net\": \"ws\",\"path\": \"$WEBSOCKET_PATH\",\"port\": \"$PORT\",\"ps\": \"$config_name\",\"scy\": \"chacha20-poly1305\",\"sni\": \"$CONFIG_DOMAIN\",\"tls\": \"tls\",\"type\": \"\",\"v\": \"2\"}" | base64 | tr -d '\n')
    server_link=$(echo -neE "{\"add\": \"$SERVER_IP\",\"aid\": \"0\",\"host\": \"$CONFIG_DOMAIN\",\"id\": \"$UUID\",\"net\": \"ws\",\"path\": \"$WEBSOCKET_PATH\",\"port\": \"$PORT\",\"ps\": \"$config_name\",\"scy\": \"chacha20-poly1305\",\"sni\": \"$CONFIG_DOMAIN\",\"tls\": \"tls\",\"type\": \"\",\"v\": \"2\"}" | base64 | tr -d '\n')

    qrencode -t ansiutf8 -l L vmess://${server_link}
    echo -ne "${Green}VMESS Link: ${Yellow}vmess://$server_link${Color_Off}\n"
}

function vmess_ws_tls() {
    check_bash
    check_root
    check_os
    disable_firewalls
    install_deps
    basic_optimization
    ip_check
    domain_check
    xray_install
    configure_certbot
    wget -O ${XRAY_CONFIG_DIRECTORY}/config.json https://raw.githubusercontent.com/thehxdev/xray-examples/main/VMess-Websocket-TLS-s/config_server.json
    judge "Download configuration"
    modify_port
    modify_UUID
    modify_ws
    modify_tls
    restart_xray
    vmess_ws_tls_link_gen
    CONFIG_PROTO="VmessWsTls"
    save_protocol
}

# ==== VMESS + WS + Nginx ====
function vmess_ws_nginx_link_gen() {
    read -rp "Choose config name: " config_name
    UUID=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].settings.clients[0].id | tr -d '"')
    WEBSOCKET_PATH=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].streamSettings.wsSettings.path | tr -d '"')
    SERVER_IP=$(curl -s4m8 https://icanhazip.com)
    server_link=$(echo -neE "{\"add\": \"$SERVER_IP\",\"aid\": \"0\",\"host\": \"\",\"id\": \"$UUID\",\"net\": \"ws\",\"path\": \"$WEBSOCKET_PATH\",\"port\": \"80\",\"ps\": \"$config_name\",\"scy\": \"chacha20-poly1305\",\"sni\": \"\",\"tls\": \"\",\"type\": \"\",\"v\": \"2\"}" | base64 | tr -d '\n')

    qrencode -t ansiutf8 -l L vmess://${server_link}
    echo -ne "${Green}VMESS Link: ${Yellow}vmess://$server_link${Color_Off}\n"
}

function users_vmess_ws_nginx_link_gen() {
    user_counter
    read -rp "Choose User: " user_number
    read -rp "Choose config name: " config_name
    UUID=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].settings.clients[${user_number}].id | tr -d '"')
    WEBSOCKET_PATH=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].streamSettings.wsSettings.path | tr -d '"')
    SERVER_IP=$(curl -s4m8 https://icanhazip.com)
    server_link=$(echo -neE "{\"add\": \"$SERVER_IP\",\"aid\": \"0\",\"host\": \"\",\"id\": \"$UUID\",\"net\": \"ws\",\"path\": \"$WEBSOCKET_PATH\",\"port\": \"80\",\"ps\": \"$config_name\",\"scy\": \"chacha20-poly1305\",\"sni\": \"\",\"tls\": \"\",\"type\": \"\",\"v\": \"2\"}" | base64 | tr -d '\n')

    qrencode -t ansiutf8 -l L vmess://${server_link}
    echo -ne "${Green}VMESS Link: ${Yellow}vmess://$server_link${Color_Off}\n"
}

function vmess_ws_nginx() {
    check_bash
    check_root
    check_os
    disable_firewalls
    install_deps
    basic_optimization
    ip_check
    port_exist_check 80
    xray_install
    install_nginx
    configure_nginx_reverse_proxy_notls
    setup_fake_website
    wget -O ${XRAY_CONFIG_DIRECTORY}/config.json https://raw.githubusercontent.com/thehxdev/xray-examples/main/VMess-Websocket-Nginx-s/server_config.json
    judge "Download configuration"
    modify_UUID
    modify_ws
    add_wsPath_to_nginx
    restart_all
    vmess_ws_nginx_link_gen
    CONFIG_PROTO="VmessWsNginx"
    save_protocol
}

# ==== VMESS + WS + Nginx + TLS ====

function vmess_ws_nginx_tls_link_gen() {
    read -rp "Choose config name: " config_name
    UUID=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].settings.clients[0].id | tr -d '"')
    WEBSOCKET_PATH=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].streamSettings.wsSettings.path | tr -d '"')
    SERVER_IP=$(curl -s4m8 https://icanhazip.com)
    CONFIG_DOMAIN=$(cat /usr/local/domain.txt)
    # server_link=$(echo -neE "{\"add\": \"$SERVER_IP\",\"aid\": \"0\",\"host\": \"\",\"id\": \"$UUID\",\"net\": \"ws\",\"path\": \"$WEBSOCKET_PATH\",\"port\": \"443\",\"ps\": \"$config_name\",\"scy\": \"chacha20-poly1305\",\"sni\": \"$CONFIG_DOMAIN\",\"tls\": \"tls\",\"type\": \"\",\"v\": \"2\"}" | base64 | tr -d '\n')
    server_link=$(echo -neE "{\"add\": \"$SERVER_IP\",\"aid\": \"0\",\"host\": \"$CONFIG_DOMAIN\",\"id\": \"$UUID\",\"net\": \"ws\",\"path\": \"$WEBSOCKET_PATH\",\"port\": \"443\",\"ps\": \"$config_name\",\"scy\": \"chacha20-poly1305\",\"sni\": \"$CONFIG_DOMAIN\",\"tls\": \"tls\",\"type\": \"\",\"v\": \"2\"}" | base64 | tr -d '\n')

    qrencode -t ansiutf8 -l L vmess://${server_link}
    echo -ne "${Green}VMESS Link: ${Yellow}vmess://$server_link${Color_Off}\n"
}

function users_vmess_ws_nginx_tls_link_gen() {
    user_counter
    read -rp "Choose User: " user_number
    read -rp "Choose config name: " config_name
    UUID=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].settings.clients[${user_number}].id | tr -d '"')
    WEBSOCKET_PATH=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].streamSettings.wsSettings.path | tr -d '"')
    SERVER_IP=$(curl -s4m8 https://icanhazip.com)
    CONFIG_DOMAIN=$(cat /usr/local/domain.txt)
    # server_link=$(echo -neE "{\"add\": \"$SERVER_IP\",\"aid\": \"0\",\"host\": \"\",\"id\": \"$UUID\",\"net\": \"ws\",\"path\": \"$WEBSOCKET_PATH\",\"port\": \"443\",\"ps\": \"$config_name\",\"scy\": \"chacha20-poly1305\",\"sni\": \"$CONFIG_DOMAIN\",\"tls\": \"tls\",\"type\": \"\",\"v\": \"2\"}" | base64 | tr -d '\n')
    server_link=$(echo -neE "{\"add\": \"$SERVER_IP\",\"aid\": \"0\",\"host\": \"$CONFIG_DOMAIN\",\"id\": \"$UUID\",\"net\": \"ws\",\"path\": \"$WEBSOCKET_PATH\",\"port\": \"443\",\"ps\": \"$config_name\",\"scy\": \"chacha20-poly1305\",\"sni\": \"$CONFIG_DOMAIN\",\"tls\": \"tls\",\"type\": \"\",\"v\": \"2\"}" | base64 | tr -d '\n')

    qrencode -t ansiutf8 -l L vmess://${server_link}
    echo -ne "${Green}VMESS Link: ${Yellow}vmess://$server_link${Color_Off}\n"
}


function vmess_ws_nginx_tls() {
    check_bash
    check_root
    check_os
    disable_firewalls
    install_deps
    basic_optimization
    ip_check
    domain_check
    configure_certbot
    port_exist_check 80
    port_exist_check 443
    xray_install
    install_nginx
    configure_nginx_reverse_proxy_tls
    add_wsPath_to_nginx
    setup_fake_website
    restart_nginx
    wget -O ${XRAY_CONFIG_DIRECTORY}/config.json https://raw.githubusercontent.com/thehxdev/xray-examples/main/VMess-Websocket-Nginx-TLS-s/server_config.json
    judge "Download configuration"
    modify_UUID
    modify_ws
    restart_all
    vmess_ws_nginx_tls_link_gen
    CONFIG_PROTO="VmessWsNginxTls"
    save_protocol
}

# VMESS + TCP
function vmess_tcp_link_gen() {
    read -rp "Choose config name: " config_name
    UUID=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].settings.clients[0].id | tr -d '"')
    PORT=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].port)
    #WEBSOCKET_PATH=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].streamSettings.wsSettings.path | tr -d '"')
    SERVER_IP=$(curl -s4m8 https://icanhazip.com)
    #CONFIG_DOMAIN=$(cat /usr/local/domain.txt)
    server_link=$(echo -neE "{\"add\": \"$SERVER_IP\",\"aid\": \"0\",\"host\": \"\",\"id\": \"$UUID\",\"net\": \"tcp\",\"path\": \"\",\"port\": \"$PORT\",\"ps\": \"$config_name\",\"scy\": \"chacha20-poly1305\",\"sni\": \"\",\"tls\": \"\",\"type\": \"\",\"v\": \"2\"}" | base64 | tr -d '\n')

    qrencode -t ansiutf8 -l L vmess://${server_link}
    echo -ne "${Green}VMESS Link: ${Yellow}vmess://$server_link${Color_Off}\n"
}

function users_vmess_tcp_link_gen() {
    user_counter
    read -rp "Choose User: " user_number
    read -rp "Choose config name: " config_name
    UUID=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].settings.clients[${user_number}].id | tr -d '"')
    PORT=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].port)
    #WEBSOCKET_PATH=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].streamSettings.wsSettings.path | tr -d '"')
    SERVER_IP=$(curl -s4m8 https://icanhazip.com)
    #CONFIG_DOMAIN=$(cat /usr/local/domain.txt)
    server_link=$(echo -neE "{\"add\": \"$SERVER_IP\",\"aid\": \"0\",\"host\": \"\",\"id\": \"$UUID\",\"net\": \"tcp\",\"path\": \"\",\"port\": \"$PORT\",\"ps\": \"$config_name\",\"scy\": \"chacha20-poly1305\",\"sni\": \"\",\"tls\": \"\",\"type\": \"\",\"v\": \"2\"}" | base64 | tr -d '\n')

    qrencode -t ansiutf8 -l L vmess://${server_link}
    echo -ne "${Green}VMESS Link: ${Yellow}vmess://$server_link${Color_Off}\n"
}

function vmess_tcp() {
    check_bash
    check_root
    check_os
    disable_firewalls
    install_deps
    basic_optimization
    ip_check
    xray_install
    wget -O ${XRAY_CONFIG_DIRECTORY}/config.json https://raw.githubusercontent.com/thehxdev/xray-examples/main/VMess-TCP-s/config_server.json
    judge "Download configuration"
    modify_port
    modify_UUID
    restart_xray
    vmess_tcp_link_gen
    CONFIG_PROTO="VmessTcp"
    save_protocol
}


# VMESS + TCP + TLS
function vmess_tcp_tls_link_gen() {
    read -rp "Choose config name: " config_name
    UUID=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].settings.clients[0].id | tr -d '"')
    PORT=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].port)
    SERVER_IP=$(curl -s4m8 https://icanhazip.com)
    CONFIG_DOMAIN=$(cat /usr/local/domain.txt)
    server_link=$(echo -neE "{\"add\": \"$SERVER_IP\",\"aid\": \"0\",\"host\": \"\",\"id\": \"$UUID\",\"net\": \"tcp\",\"path\": \"/\",\"port\": \"$PORT\",\"ps\": \"$config_name\",\"scy\": \"chacha20-poly1305\",\"sni\": \"$CONFIG_DOMAIN\",\"tls\": \"tls\",\"type\": \"http\",\"v\": \"2\"}" | base64 | tr -d '\n')

    qrencode -t ansiutf8 -l L vmess://${server_link}
    echo -ne "${Green}VMESS Link: ${Yellow}vmess://$server_link${Color_Off}\n"
}

function users_vmess_tcp_tls_link_gen() {
    user_counter
    read -rp "Choose User: " user_number
    read -rp "Choose config name: " config_name
    UUID=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].settings.clients[${user_number}].id | tr -d '"')
    PORT=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].port)
    #WEBSOCKET_PATH=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].streamSettings.wsSettings.path | tr -d '"')
    SERVER_IP=$(curl -s4m8 https://icanhazip.com)
    CONFIG_DOMAIN=$(cat /usr/local/domain.txt)
    server_link=$(echo -neE "{\"add\": \"$SERVER_IP\",\"aid\": \"0\",\"host\": \"\",\"id\": \"$UUID\",\"net\": \"tcp\",\"path\": \"/\",\"port\": \"$PORT\",\"ps\": \"$config_name\",\"scy\": \"chacha20-poly1305\",\"sni\": \"$CONFIG_DOMAIN\",\"tls\": \"tls\",\"type\": \"http\",\"v\": \"2\"}" | base64 | tr -d '\n')

    qrencode -t ansiutf8 -l L vmess://${server_link}
    echo -ne "${Green}VMESS Link: ${Yellow}vmess://$server_link${Color_Off}\n"
}

function vmess_tcp_tls() {
    check_bash
    check_root
    check_os
    disable_firewalls
    install_deps
    basic_optimization
    ip_check
    domain_check
    configure_certbot
    xray_install
    wget -O ${XRAY_CONFIG_DIRECTORY}/config.json https://raw.githubusercontent.com/thehxdev/xray-examples/main/VMess-TCP-TLS-s/config_server.json
    judge "Download configuration"
    modify_port
    modify_UUID
    modify_tls
    restart_xray
    vmess_tcp_tls_link_gen
    CONFIG_PROTO="VmessTcpTls"
    save_protocol
}

# ========== Trojan ========== #

# ==== Torojan + TCP + TLS ====

function trojan_tcp_tls_link_gen() {
    read -rp "Choose config name: " config_name
    #UUID=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].settings.clients[0].id | tr -d '"')
    PORT=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].port)
    #WEBSOCKET_PATH=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].streamSettings.wsSettings.path | tr -d '"')
    SERVER_IP=$(curl -s4m8 https://icanhazip.com)
    CONFIG_DOMAIN=$(cat /usr/local/domain.txt)
    PASSWORD=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].settings.clients[0].password | tr -d '"')
    server_link=$(echo -neE "$PASSWORD@$SERVER_IP:$PORT?sni=$CONFIG_DOMAIN&security=tls&type=tcp#$config_name")

    qrencode -t ansiutf8 -l L trojan://${server_link}
    echo -ne "${Green}Trojan Link: ${Yellow}trojan://$server_link${Color_Off}\n"
}

function users_trojan_tcp_tls_link_gen() {
    user_counter
    read -rp "Choose User: " user_number
    read -rp "Choose config name: " config_name
    #UUID=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].settings.clients[0].id | tr -d '"')
    PORT=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].port)
    #WEBSOCKET_PATH=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].streamSettings.wsSettings.path | tr -d '"')
    SERVER_IP=$(curl -s4m8 https://icanhazip.com)
    CONFIG_DOMAIN=$(cat /usr/local/domain.txt)
    PASSWORD=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].settings.clients[${user_number}].password | tr -d '"')
    server_link=$(echo -neE "$PASSWORD@$SERVER_IP:$PORT?sni=$CONFIG_DOMAIN&security=tls&type=tcp#$config_name")

    qrencode -t ansiutf8 -l L trojan://${server_link}
    echo -ne "${Green}Trojan Link: ${Yellow}trojan://$server_link${Color_Off}\n"
}

function trojan_tcp_tls() {
    check_bash
    check_root
    check_os
    disable_firewalls
    install_deps
    basic_optimization
    ip_check
    domain_check
    xray_install
    configure_certbot
    wget -O ${XRAY_CONFIG_DIRECTORY}/config.json https://raw.githubusercontent.com/thehxdev/xray-examples/main/Trojan-TCP-TLS-s/config_server.json
    judge "Download configuration"
    modify_port
    modify_PASSWORD
    modify_tls
    restart_xray
    trojan_tcp_tls_link_gen
    CONFIG_PROTO="TrojanTcpTls"
    save_protocol
}

# ==== Torojan + WS + TLS ====

function trojan_ws_tls_link_gen() {
    read -rp "Choose config name: " config_name
    #UUID=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].settings.clients[0].id | tr -d '"')
    PORT=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].port)
    WEBSOCKET_PATH=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].streamSettings.wsSettings.path | tr -d '"')
    SERVER_IP=$(curl -s4m8 https://icanhazip.com)
    CONFIG_DOMAIN=$(cat /usr/local/domain.txt)
    PASSWORD=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].settings.clients[0].password | tr -d '"')
    # server_link=$(echo -neE "$PASSWORD@$SERVER_IP:$PORT?sni=$CONFIG_DOMAIN&security=tls&type=ws&path=$WEBSOCKET_PATH#$config_name")
    server_link=$(echo -neE "$PASSWORD@$SERVER_IP:$PORT?sni=$CONFIG_DOMAIN&security=tls&type=ws&path=$WEBSOCKET_PATH&host=$CONFIG_DOMAIN#$config_name")

    qrencode -t ansiutf8 -l L trojan://${server_link}
    echo -ne "${Green}Trojan Link: ${Yellow}trojan://$server_link${Color_Off}\n"
}

function users_trojan_ws_tls_link_gen() {
    user_counter
    read -rp "Choose User: " user_number
    read -rp "Choose config name: " config_name
    PORT=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].port)
    WEBSOCKET_PATH=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].streamSettings.wsSettings.path | tr -d '"')
    SERVER_IP=$(curl -s4m8 https://icanhazip.com)
    CONFIG_DOMAIN=$(cat /usr/local/domain.txt)
    PASSWORD=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].settings.clients[${user_number}].password | tr -d '"')
    # server_link=$(echo -neE "$PASSWORD@$SERVER_IP:$PORT?sni=$CONFIG_DOMAIN&security=tls&type=ws&path=$WEBSOCKET_PATH#$config_name")
    server_link=$(echo -neE "$PASSWORD@$SERVER_IP:$PORT?sni=$CONFIG_DOMAIN&security=tls&type=ws&path=$WEBSOCKET_PATH&host=$CONFIG_DOMAIN#$config_name")

    qrencode -t ansiutf8 -l L trojan://${server_link}
    echo -ne "${Green}Trojan Link: ${Yellow}trojan://$server_link${Color_Off}\n"
}

function trojan_ws_tls() {
    check_bash
    check_root
    check_os
    disable_firewalls
    install_deps
    basic_optimization
    ip_check
    domain_check
    xray_install
    configure_certbot
    #get_ssl_cert
    wget -O ${XRAY_CONFIG_DIRECTORY}/config.json https://raw.githubusercontent.com/thehxdev/xray-examples/main/Trojan-Websocket-TLS-s/config_server.json
    judge "Download configuration"
    modify_port
    modify_ws
    modify_PASSWORD
    modify_tls
    restart_xray
    trojan_ws_tls_link_gen
    CONFIG_PROTO="TrojanWsTls"
    save_protocol
}

# ===================================== #

# Dokodemo
function dokodemo_door_setup() {
    check_bash
    check_root
    check_os
    disable_firewalls
    install_deps
    basic_optimization
    ip_check
    xray_install
    read -rp "Enter Listening Port: " LISTENING_PORT
    read -rp "Enter Foreign Server IP Address: " FOREIGN_SERVER_IP
    read -rp "Enter Foreign Server Port: " FOREIGN_SERVER_PORT
    cat << EOF > ${XRAY_CONFIG_DIRECTORY}/config.json
{
    "inbounds": [
        {
            "port": ${LISTENING_PORT},
            "listen": "0.0.0.0",
            "protocol": "dokodemo-door",
            "settings": {
                "address": "${FOREIGN_SERVER_IP}",
                "port": ${FOREIGN_SERVER_PORT},
                "network": "tcp,udp",
                "timeout": 0,
                "followRedirect": false,
                "userLevel": 0
            }
        }
    ],
    "outbounds": [
        {
            "protocol": "freedom"
        }
    ]
}
EOF
    restart_xray
    CONFIG_PROTO="dokodemo"
    save_protocol
}

function shecan_dns() {
    ip_check
    if [[ -z ${local_ipv4} && -n ${local_ipv6} ]]; then
        print_error "Shecan does not support IPv6"
        exit 1
    else
        echo "nameserver 178.22.122.100" > /etc/resolv.conf
        echo "nameserver 185.51.200.2" >> /etc/resolv.conf
        judge "add IPv4 DNS to resolv.conf"
    fi
}

# ===================================== #

# Get Config Link
function save_protocol() {
    if [[ -e "/usr/local/etc/xray" ]]; then
        #echo "${CONFIG_PROTO}" > /usr/local/etc/xray/proto.txt
        echo "${CONFIG_PROTO}" > ${proto_file}
    fi
}

function check_domain_file() {
    if [[ -e "/usr/local/domain.txt" ]]; then
        print_ok "domain file found!"
    else
        echo -e "${Yellow}domain.txt file not found!${Color_Off}"
        read -rp "Enter Your domain: " user_domain
        echo -e "${user_domain}" > /usr/local/domain.txt
        judge "add user domain to domain.txt"
    fi
}

function get_config_link() {
    if [[ -e "${proto_file}" ]]; then
        CURRENT_CONFIG=$(cat ${proto_file})
        print_ok "proto.txt file found!"
    else
        get_current_protocol
        CURRENT_CONFIG=$(cat ${proto_file})
    fi

    if [[ ${CURRENT_CONFIG} == "VlessWsTls" ]]; then
        check_domain_file
        users_vless_ws_tls_link_gen
    elif [[ ${CURRENT_CONFIG} == "VlessTcpTls" ]]; then
        check_domain_file
        users_vless_tcp_tls_link_gen
    elif [[ ${CURRENT_CONFIG} == "VmessWs" ]]; then
        users_vmess_ws_link_gen
    elif [[ ${CURRENT_CONFIG} == "VmessWsTls" ]]; then
        check_domain_file
        users_vmess_ws_tls_link_gen
    elif [[ ${CURRENT_CONFIG} == "VmessWsNginx" ]]; then
        users_vmess_ws_nginx_link_gen
    elif [[ ${CURRENT_CONFIG} == "VmessWsNginxTls" ]]; then
        check_domain_file
        users_vmess_ws_nginx_tls_link_gen
    elif [[ ${CURRENT_CONFIG} == "VmessTcp" ]]; then
        users_vmess_tcp_link_gen
    elif [[ ${CURRENT_CONFIG} == "VmessTcpTls" ]]; then
        check_domain_file
        users_vmess_tcp_tls_link_gen
    elif [[ ${CURRENT_CONFIG} == "TrojanTcpTls" ]]; then
        check_domain_file
        users_trojan_tcp_tls_link_gen
    elif [[ ${CURRENT_CONFIG} == "TrojanWsTls" ]]; then
        check_domain_file
        users_trojan_ws_tls_link_gen
    fi
}

# ===================================== #

# Define current protocol
function get_current_protocol() {
    if [ ! -e "${proto_file}" ]; then
        if grep -q "vless" ${XRAY_CONFIG_FILE} && grep -q "wsSettings" ${XRAY_CONFIG_FILE} && grep -q "tlsSettings" ${XRAY_CONFIG_FILE}; then
            echo -e "VlessWsTls" > ${proto_file}
            judge "add VlessWsTls to proto.txt"

        elif grep -q "vless" ${XRAY_CONFIG_FILE} && grep -q "tcp" ${XRAY_CONFIG_FILE} && grep -q "tlsSettings" ${XRAY_CONFIG_FILE}; then
            echo -e "VlessTcpTls" > ${proto_file}
            judge "add VlessTcpTls to proto.txt"

        elif grep -q "vmess" ${XRAY_CONFIG_FILE} && grep -q "wsSettings" ${XRAY_CONFIG_FILE} && ! grep -q "tlsSettings" ${XRAY_CONFIG_FILE} && ! grep -q "127.0.0.1" ${XRAY_CONFIG_FILE}; then
            echo -e "VmessWs" > ${proto_file}
            judge "add VmessWs to proto.txt"

        elif grep -q "vmess" ${XRAY_CONFIG_FILE} && grep -q "wsSettings" ${XRAY_CONFIG_FILE} && grep -q "tlsSettings" ${XRAY_CONFIG_FILE} && ! grep -q "127.0.0.1" ${XRAY_CONFIG_FILE}; then
            echo -e "VmessWsTls" > ${proto_file}
            judge "add VmessWsTls to proto.txt"

        elif grep -q "vmess" ${XRAY_CONFIG_FILE} && grep -q "127.0.0.1" ${XRAY_CONFIG_FILE} && ! grep -q "ssl_certificate" ${nginx_conf}; then
            echo -e "VmessWsNginx" > ${proto_file}
            judge "add VmessWsNginx to proto.txt"

        elif grep -q "vmess" ${XRAY_CONFIG_FILE} && grep -q "127.0.0.1" ${XRAY_CONFIG_FILE} && grep -q "ssl_certificate" ${nginx_conf}; then
            echo -e "VmessWsNginxTls" > ${proto_file}
            judge "add VmessWsNginxTls to proto.txt"

        elif grep -q "vmess" ${XRAY_CONFIG_FILE} && grep -q "tcp" ${XRAY_CONFIG_FILE} && ! grep -q "tlsSettings" ${XRAY_CONFIG_FILE}; then
            echo -e "VmessTcp" > ${proto_file}
            judge "add VmessTcp to proto.txt"

        elif grep -q "vmess" ${XRAY_CONFIG_FILE} && grep -q "tcp" ${XRAY_CONFIG_FILE} && grep -q "tlsSettings" ${XRAY_CONFIG_FILE}; then
            echo -e "VmessTcpTls" > ${proto_file}
            judge "add VmessTcpTls to proto.txt"

        elif grep -q "trojan" ${XRAY_CONFIG_FILE} && grep -q "tcp" ${XRAY_CONFIG_FILE}; then
            echo -e "TrojanTcpTls" > ${proto_file}
            judge "add TrojanTcpTls to proto.txt"

        elif grep -q "trojan" ${XRAY_CONFIG_FILE} && grep -q "wsSettings"; then
            echo -e "TrojanWsTls" > ${proto_file}
            judge "add TrojanWsTls to proto.txt"

        else
            print_error "Can't detect your configureation"
            exit 1
        fi
    else
        print_ok "proto.txt file exist"
    fi
}

# ===================================== #

function make_backup() {
    if [ ! -e ${backup_dir} ]; then
        mkdir ${backup_dir} >/dev/null 2>&1
        judge "make bakup directory" 
    else
        print_ok "backup directory exist!"
        rm -rf /root/old_xray_backups/*
        judge "make old_xray_backups directory empty"
        mkdir /root/old_xray_backups/ >/dev/null 2>&1
        mv ${backup_dir} /root/old_xray_backups/
        judge "move existing backup to /root/old_xray_backups"
        mkdir ${backup_dir} >/dev/null 2>&1
        if [ -e "/root/xray_backup.tar.gz" ]; then
            mv /root/xray_backup.tar.gz /root/old_xray_backups/
            judge "move existing backup.tar.gz to /root/old_xray_backups"
        fi
    fi

    if [ -e ${XRAY_CONFIG_DIRECTORY} ]; then
        mkdir ${backup_dir}/xray >/dev/null 2>&1
        cp -r ${XRAY_CONFIG_DIRECTORY}/* ${backup_dir}/xray/
        judge "copy xray configurations"
        if [ -e "/usr/local/domain.txt" ]; then
            cp /usr/local/domain.txt ${backup_dir}
            judge "copy domain.txt file"
        fi
    fi

    if [ -e "/etc/nginx" ]; then
        WEBSOCKET_PATH=$(cat ${XRAY_CONFIG_DIRECTORY}/config.json | jq .inbounds[0].streamSettings.wsSettings.path | tr -d '"')
        WEBSOCKET_PATH_IN_NGINX=$(grep -o ${WEBSOCKET_PATH} ${nginx_conf})
        if [[ -n ${WEBSOCKET_PATH} && -n ${WEBSOCKET_PATH_IN_NGINX} ]]; then
            if [[ ${WEBSOCKET_PATH} == ${WEBSOCKET_PATH_IN_NGINX} ]]; then
                cp -r /etc/nginx/ ${backup_dir}
                judge "copy nginx configurations"
            else
                print_info "Nginx WebSocket path and Xray WebSocket path are not same as each other."
                print_info "Probably Nginx is not used for Xray!"
                print_info "Nginx Backup Skipped!"
            fi
        else
            print_info "Nginx WebSocket path or Xray WebSocket path is NOT defined."
            print_info "Probably Nginx is not used for Xray!"
            print_info "Nginx Backup Skipped!"
        fi
    else
        print_info "nginx config files not found or not installed. No Problem!"
    fi

    if [[ -e "/ssl" ]]; then
        cp -r /ssl ${backup_dir}
        judge "copy SSL certs for xray"
    else
        print_info "No SSL certificate found for xray. No problem!"
    fi

    if [[ -e "${users_expiry_date_file}" ]]; then
        cp -r ${users_expiry_date_file} ${backup_dir}
        judge "Copy users expiry date file"
    else
        print_info "Users expiry date file not found! Skipping..."
    fi

    if ! command -v gzip; then
        installit gzip tar
    else
        print_ok "gzip installed"
    fi

    tar -czf /root/xray_backup.tar.gz -C ${backup_dir} .
    judge "Compress and put backup files if one .tar.gz file"
}

function restore_backup() {
    if [[ ! -e "/usr/local/bin/xray" && ! -e "/usr/local/etc/xray" ]]; then
        print_info "xray is not installed" && sleep 0.5
        print_info "installing xray-core" && sleep 1
        xray_install
    else
        print_ok "xray is installed"
    fi

    if [[ -e "/root/xray_backup" ]]; then
        mv /root/xray_backup /root/old_xray_backups
        judge "rename old backup dir to xray_backup_old"
        mkdir /root/xray_backup >/dev/null 2>&1
        judge "create new xray_backup"
    else
        mkdir /root/xray_backup >/dev/null 2>&1
        judge "create new xray_backup"
    fi

    if [[ -e "/root/xray_backup.tar.gz" ]]; then
        tar -xzf /root/xray_backup.tar.gz -C /root/xray_backup
        judge "extract backup file"
    else
        print_error "can't find xray_backup.tar.gz! if you have a backup file put it into /root/ directory and rename it to xray_backup.tar.gz"
        exit 1
    fi

    if [[ -e "${backup_dir}" ]]; then
        if [[ -e "${backup_dir}/nginx" ]]; then
            cp -r ${backup_dir}/nginx /etc/
            judge "restore nginx config"
            if command -v nginx; then
                systemctl restart nginx
                judge "restart nginx"
            else
                print_info "nginx is not installed"
                install_nginx
                systemctl restart nginx
                judge "restart nginx after fresh install"
            fi
        fi

        if [[ -e "${backup_dir}/xray" ]]; then
            if [[ -e "${XRAY_CONFIG_DIRECTORY}" ]]; then
                rm -rf ${XRAY_CONFIG_DIRECTORY}/*
                judge "remove old configs"
                cp -r ${backup_dir}/xray/* ${XRAY_CONFIG_DIRECTORY}/
                judge "restore xray files"
                systemctl restart xray
                judge "restart xray"
            else
                print_error "${XRAY_CONFIG_DIRECTORY} not found"
            fi
        fi

        if [[ -e "${backup_dir}/domain.txt" ]]; then
            cp ${backup_dir}/domain.txt /usr/local/domain.txt
            judge "restore domain.txt"
        fi

        if [[ -e "${backup_dir}/ssl" ]]; then
            if [[ -e "/ssl/xray.crt" && -e "/ssl/xray.key" ]]; then
                print_info "You already have SSL certificates in your /ssl/ directory. Do you want to replace them with old ones? [y/n]"
                read -r replace_old_ssl
                case $replace_old_ssl in
                [yY][eE][sS] | [yY])
                    mv /ssl /ssl_old
                    judge "rename /ssl dir"
                    cp -r ${backup_dir}/ssl /
                    judge "restore SSL certificates for xray"
                    chown -R nobody.$cert_group /ssl/*
                    ;;
                *) 
                    print_info "SSL certificates remained untouched"
                    ;;
                esac
            fi
        else
            cp -r ${backup_dir}/ssl /
            judge "restore SSL certificates for xray"
        fi

        if [[ -e "${backup_dir}/users_expiry_date.txt" ]]; then
            cp -r ${backup_dir}/${users_expiry_date_file} ${XRAY_CONFIG_DIRECTORY}/
            judge "Restore users expiry date file"
        else
            print_info "Users expiry date file not found! Skipping..."
        fi

        print_ok "Bakup restore Finished"
    fi
}

# ===================================== #

# Xray Status

function xray_status() {
    systemd_xray_status=$(systemctl status xray | grep Active | grep -Eo "active|inactive|failed")
    if [[ ${systemd_xray_status} == "active" ]]; then
        echo -e "${Green}Active${Color_Off}"
        xray_status_var="active"
        exit 0
    elif [[ ${systemd_xray_status} == "inactive" ]]; then
        echo -e "${Red}Inactive${Color_Off}"
        xray_status_var="inactive"
        exit 0
    elif [[ ${systemd_xray_status} == "failed" ]]; then
        echo -e "${Red}failed${Color_Off}"
        xray_status_var="failed"
        exit 0
    fi
}

# Nginx Status

function nginx_status() {
    if ! command -v nginx; then
        print_info "Nginx is not installed"
        exit 1
    else
        systemd_nginx_status=$(systemctl status nginx | grep Active | grep -Eo "active|inactive")
        if [[ ${systemd_nginx_status} == "active" ]]; then
            echo -e "${Green}Active${Color_Off}"
            nginx_status_var="active"
            exit 0
        elif [[ ${systemd_nginx_status} == "inactive" ]]; then
            echo -e "${Red}Inactive${Color_Off}"
            nginx_status_var="inactive"
            exit 0
        fi
    fi
}

# ===================================== #

# Read Xray Config

function read_current_config() {
    if [[ -e "${XRAY_CONFIG_FILE}" ]]; then
        current_port=$(cat ${XRAY_CONFIG_FILE} | jq .inbounds[0].port)
        current_protocol=$(cat ${XRAY_CONFIG_FILE} | jq .inbounds[0].protocol)
        current_users_count=$(cat ${users_count_file})
        current_network=$(cat ${XRAY_CONFIG_FILE} | jq .inbounds[0].streamSettings.network)
        current_ws_path=$(cat ${XRAY_CONFIG_FILE} | jq .inbounds[0].streamSettings.wsSettings.path)
        current_security=$(cat ${XRAY_CONFIG_FILE} | jq .inbounds[0].streamSettings.security)
        current_active_connections=$(ss -tnp | grep "xray" | awk '{print $5}' | grep "\[::ffff" | grep -Eo "[0-9]{1,3}(\.[0-9]{1,3}){3}" | sort | uniq | wc -l)

        echo -e "========================================="
        echo -e "Users Count: ${current_users_count}"

        if [[ ${current_port} == "10000" ]]; then
            if grep -q "127.0.0.1" ${XRAY_CONFIG_FILE}; then
                echo -e "Port: 443 (Nginx)"
            else
                echo -e "Port: ${current_port}"
            fi
        else
            echo -e "Port: ${current_port}"
        fi

        echo -e "Protocol: ${current_protocol}"
        echo -e "Network: ${current_network}"

        if [[ -n ${current_ws_path} ]]; then
            echo -e "WebSocket Path: ${current_ws_path}"
        else
            echo -e "Websocket Path: None or Not Used"
        fi

        echo -e "Security: ${current_security}"

        if [[ -n ${current_active_connections} ]]; then
            echo -e "Active Connections: ${current_active_connections}"
        fi

        echo -e "========================================="
    else
        print_error "Xray config NOT found! Probably Xray is not installed!"
        exit 1
    fi
}

# ===================================== #

function get_ssl_certificate() {
    check_bash
    check_root
    check_os

    #if [ -e "/ssl/xray.crt" && -e "/ssl/xray.key" ]; then
    #	print_info "You Already have SSL certificates for Xray! Do you want to remove them? [y/n]"
    #	read -r remove_ssl_certs
    #	case $remove_ssl_certs in
    #	[yY][eE][sS] | [yY])
    #		apt purge certbot python3-certbot -y
    #		rm -rf /etc/letsencrypt/
    #		rm -rf /var/log/letsencrypt/
    #		rm -rf /etc/systemd/system/*certbot*
    #		rm -rf /ssl/
    #		;;
    #	*) ;;
    #	esac
    #fi

    disable_firewalls
    install_deps
    basic_optimization
    ip_check
    domain_check

    if [[ ! -e "/usr/local/bin/xray" && ! -e "${XRAY_CONFIG_DIRECTORY}" ]]; then
        xray_install
    else
        print_ok "xray is already installed"
    fi

    if id -u nobody >/dev/null; then
        print_ok "user nobody exist"
        groupadd nobody
        gpasswd -a nobody nobody
        judge "add nobody user to nobody group"
    else
        useradd nobody
        judge "create nobody user"
        groupadd nobody
        gpasswd -a nobody nobody
        judge "add nobody user to nobody group"
    fi
    configure_certbot
}

# ===================================== #
function xray_setup_menu() {
    clear
    echo -e "====================  VLESS  ======================"
    echo -e "${Green}1. VLESS + WS + TLS${Color_Off}"
    echo -e "${Green}2. VLESS + TCP + TLS${Color_Off}"
    echo -e "====================  VMESS  ======================"
    echo -e "${Green}3. VMESS + WS ${Red}(NOT Recommended - Low Security)${Color_Off}"
    echo -e "${Green}4. VMESS + WS + TLS${Color_Off}"
    echo -e "${Green}5. VMESS + WS + Nginx (No TLS)${Color_Off}"
    echo -e "${Green}6. VMESS + WS + Nginx (TLS)${Color_Off}"
    echo -e "${Green}7. VMESS + TCP ${Red}(NOT Recommended - Low Security)${Color_Off}"
    echo -e "${Green}8. VMESS + TCP + TLS${Color_Off}"
    echo -e "====================  TROJAN  ====================="
    echo -e "${Green}9. Trojan + TCP + TLS${Color_Off}"
    echo -e "${Green}10. Trojan + WS + TLS${Color_Off}"
    echo -e "===================================================="
    echo -e "${Yellow}11. Exit${Color_Off}\n"
    read -rp "Enter an Option: " menu_num
    case $menu_num in
    1)
        vless_ws_tls
        echo -e "1" > ${users_count_file}
        echo -e "1" > ${users_number_in_config_file}
        ;;
    2)
        vless_tcp_tls
        echo -e "1" > ${users_count_file}
        echo -e "1" > ${users_number_in_config_file}
        ;;
    3)
        vmess_ws
        echo -e "1" > ${users_count_file}
        echo -e "1" > ${users_number_in_config_file}
        ;;
    4)
        vmess_ws_tls
        echo -e "1" > ${users_count_file}
        echo -e "1" > ${users_number_in_config_file}
        ;;
    5)
        vmess_ws_nginx
        echo -e "1" > ${users_count_file}
        echo -e "1" > ${users_number_in_config_file}
        ;;
    6)
        vmess_ws_nginx_tls
        echo -e "1" > ${users_count_file}
        echo -e "1" > ${users_number_in_config_file}
        ;;
    7)
        vmess_tcp
        echo -e "1" > ${users_count_file}
        echo -e "1" > ${users_number_in_config_file}
        ;;
    8)
        vmess_tcp_tls
        echo -e "1" > ${users_count_file}
        echo -e "1" > ${users_number_in_config_file}
        ;;
    9)
        trojan_tcp_tls
        ;;
    10)
        trojan_ws_tls
        ;;
    11)
        exit 0
        ;;
    *)
        print_error "Invalid Option. Run script again!"
        exit 1
    esac
}

function forwarding_menu() {
    clear
    echo -e "=================== Forwarding ==================="
    echo -e "${Green}1. Send Golang and Gost to domestic relay${Color_Off}"
    echo -e "${Green}2. Install and configure Gost ${Cyan}(Run on domestic relay)${Color_Off}"
    echo -e "${Green}3. Install and configure Xray Dokodemo-door ${Cyan}(Run on domestic relay)${Color_Off}"
    echo -e "${Yellow}4. Exit${Color_Off}\n"
    read -rp "Enter an Option: " menu_num
    case $menu_num in
    1)
        send_go_and_gost
        ;;
    2)
        configure_gost_and_go
        ;;
    3)
        dokodemo_door_setup
        ;;
    4)
        exit 0
        ;;
    *)
        print_error "Invalid Option. Run script again!"
        exit 1
    esac
}

function xray_and_vps_settings() {
    clear
    echo -e "========== Settings =========="
    echo -e "${Green}1. Change vps DNS to Cloudflare${Color_Off}"
    echo -e "${Green}2. Change vps DNS to Shecan${Color_Off}"
    echo -e "${Green}3. Enable BBR TCP Boost${Color_Off}"
    echo -e "${Green}4. Get Xray Status${Color_Off}"
    echo -e "${Green}5. Get Nginx Status${Color_Off}"
    echo -e "${Green}6. Get Current Xray Config Info${Color_Off}"
    echo -e "${Green}7. Install Xray and Get SSL Certificate - No Configuration (If Xray already installed it only gets SSL certs)${Color_Off}"
    echo -e "${Yellow}8. Exit${Color_Off}\n"
    read -rp "Enter an Option: " menu_num
    case $menu_num in
    1)
        cloudflare_dns
        ;;
    2)
        shecan_dns
        ;;
    3)
        bbr_boost
        ;;
    4)
        xray_status
        ;;
    5)
        nginx_status
        ;;
    6)
        read_current_config
        ;;
    7)
        get_ssl_certificate
        ;;
    8)
        exit 0
        ;;
    *)
        print_error "Invalid Option. Run script again!"
        exit 1
    esac
}

function user_management_and_backup_menu() {
    clear
    echo -e "=============== User Management ================"
    echo -e "${Cyan}1. Get Users Configuration Link${Color_Off}"
    echo -e "${Blue}2. User Management System${Color_Off}"
    echo -e "=================== Backup ====================="
    echo -e "${Green}3. Make Backup${Color_Off}"
    echo -e "${Green}4. Restore existing backup${Color_Off}"
    echo -e "${Yellow}5. Exit${Color_Off}\n"
    read -rp "Enter an Option: " menu_num
    case $menu_num in
    1)
        get_config_link
        ;;
    2)
        if ! command -v jq; then
            apt update && apt install jq
        fi
        bash -c "$(curl -L https://github.com/thehxdev/xray-install/raw/main/manage_xray_users.sh)"
        ;;
    3)
        make_backup
        ;;
    4)
        restore_backup
        ;;
    5)
        exit 0
        ;;
    *)
        print_error "Invalid Option. Run script again!"
        exit 1
    esac
}

function greetings_screen() {
    clear
    echo -e '
$$\   $$\ $$$$$$$\   $$$$$$\ $$\     $$\       $$\   $$\ $$\   $$\ 
$$ |  $$ |$$ .__$$\ $$  __$$\ $$\   $$  |      $$ |  $$ |$$ |  $$ |
\$$\ $$  |$$ |  $$ |$$ /  $$ |\$$\ $$  /       $$ |  $$ |\$$\ $$  |
 \$$$$  / $$$$$$$  |$$$$$$$$ | \$$$$  /        $$$$$$$$ | \$$$$  / 
 $$  $$<  $$ .__$$< $$ .__$$ |  \$$  /         $$ .__$$ | $$  $$<  
$$  /\$$\ $$ |  $$ |$$ |  $$ |   $$ |          $$ |  $$ |$$  /\$$\ 
$$ /  $$ |$$ |  $$ |$$ |  $$ |   $$ |          $$ |  $$ |$$ /  $$ |
\__|  \__|\__|  \__|\__|  \__|   \__|          \__|  \__|\__|  \__|

=> by thehxdev
=> https://github.com/thehxdev/
'

    echo -e "${Green}1. Setup Xray${Color_Off}"
    echo -e "${Green}2. Forwarding Tools${Color_Off}"
    echo -e "${Green}3. Xray and VPS Settings${Color_Off}"
    echo -e "${Green}4. User Management and Backup Tools${Color_Off}"
    echo -e "${Red}5. Uninstall Xray${Color_Off}"
    echo -e "${Yellow}6. Exit${Color_Off}\n"

    read -rp "Enter an Option: " menu_num
    case $menu_num in
    1)
        xray_setup_menu
        ;;
    2)
        forwarding_menu
        ;;
    3)
        xray_and_vps_settings
        ;;
    4)
        user_management_and_backup_menu
        ;;
    5)
        xray_uninstall
        ;;
    6)
        exit 0
        ;;
    *)
        print_error "Invalid Option. Run script again!"
        exit 1
    esac
}

greetings_screen "$@"

