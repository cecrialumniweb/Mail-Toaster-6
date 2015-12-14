#!/bin/sh

. mail-toaster.sh || exit

export SAFE_NAME; SAFE_NAME=$(safe_jailname "$BASE_NAME") || exit

update_host_ntpd()
{
    tell_status "enabling NTPd"
    sysrc ntpd_enable=YES || exit
    sysrc ntpd_sync_on_start=YES
    /etc/rc.d/ntpd restart
}

update_syslogd()
{
    tell_status "turn off syslog network listener"
    sysrc syslogd_flags=-ss
    service syslogd restart
}

update_sendmail()
{
    tell_status "turn off sendmail network listening"
    sysrc sendmail_enable=NO
    service sendmail onestop
}

constrain_sshd_to_host()
{
    if ! sockstat -L | egrep '\*:22 '; then
        return
    fi

    get_public_ip
    get_public_ip ipv6
    local _sshd_conf="/etc/ssh/sshd_config"

    local _confirm_msg="
    To not interfere with the jails, sshd must be constrained to
    listening on your hosts public facing IP(s).

    Your public IPs are detected as $PUBLIC_IP4
        and $PUBLIC_IP6

    May I update $_sshd_conf?
    "
    dialog --yesno "$_confirm_msg" 13 70 || exit

    tell_status "Limiting SSHd to host IP address"

    sed -i -e "s/#ListenAddress 0.0.0.0/ListenAddress $PUBLIC_IP4/" $_sshd_conf
    if [ -n "$PUBLIC_IP6" ]; then
        sed -i -e "s/#ListenAddress ::/ListenAddress $PUBLIC_IP6/" $_sshd_conf
    fi

    # grep ^Listen /etc/ssh/sshd_config
    service sshd restart
}

check_global_listeners()
{
    tell_status "checking for host listeners on all IPs"

    if sockstat -L | egrep '\*:[0-9]' | grep -v 123; then
        echo "oops!, you should not having anything listening
        on all your IP addresses!"
        exit 2
    fi
}

add_jail_nat()
{
    tell_status "enabling NAT for jails"

    grep -qs bruteforce /etc/pf.conf || tee -a /etc/pf.conf <<EO_PF_RULES
ext_if="$PUBLIC_NIC"
table <ext_ips> { $PUBLIC_IP4 $PUBLIC_IP6 }
table <bruteforce>  persist

# default route to the internet for jails
nat on \$ext_if from $JAIL_NET_PREFIX.0${JAIL_NET_MASK} to any -> (\$ext_if)

# POP3 & IMAP traffic to dovecot jail
rdr proto tcp from any to <ext_ips> port { 110 143 993 995 } -> $JAIL_NET_PREFIX.15

# SMTP traffic to the Haraka jail
rdr proto tcp from any to <ext_ips> port { 25 465 587 } -> $JAIL_NET_PREFIX.9

# HTTP traffic to HAproxy
rdr proto tcp from any to <ext_ips> port { 80 443 } -> $JAIL_NET_PREFIX.12

block in quick from <bruteforce>
EO_PF_RULES

    _pf_loaded=$(kldstat -m pf | grep pf)
    if [ -n "$_pf_loaded" ]; then
        pfctl -f /etc/pf.conf 2>/dev/null || exit
    else
        kldload pf
    fi

    sysrc pf_enable=YES
    /etc/rc.d/pf restart 2>/dev/null || exit
}

install_jailmanage()
{
    pkg install -y ca_root_nss || exit
    fetch -o /usr/local/sbin/jailmanage https://www.tnpi.net/computing/freebsd/jail_manage.txt
    chmod 755 /usr/local/sbin/jailmanage || exit
}

set_jail_startup_order()
{
    patch -d / <<'EO_JAIL_RCD'
Index: etc/rc.d/jail
===================================================================
--- etc/rc.d/jail
+++ etc/rc.d/jail
@@ -516,7 +516,10 @@
 		command=$jail_program
 		rc_flags=$jail_flags
 		command_args="-f $jail_conf -r"
-		$jail_jls name | while read _j; do
+		for _j in $($jail_jls name); do
+			_rev_jail_list="${_j} ${_rev_jail_list}"
+		done
+		for _j in ${_rev_jail_list}; do
 			echo -n " $_j"
 			_tmp=`mktemp -t jail` || exit 3
 			$command $rc_flags $command_args $_j >> $_tmp 2>&1
@@ -532,6 +535,9 @@
 	;;
 	esac
 	for _j in $@; do
+		_rev_jail_list="${_j} ${_rev_jail_list}"
+	done
+	for _j in ${_rev_jail_list}; do
 		_j=$(echo $_j | tr /. _)
 		parse_options $_j || continue
 		if ! $jail_jls -j $_j > /dev/null 2>&1; then
EO_JAIL_RCD

    # sysrc jail_list="dns mysql vpopmail dovecot webmail haproxy clamav avg rspamd spamassassin haraka dspam monitor"
}

enable_jails()
{
    #set_jail_startup_order

    sysrc jail_enable=YES

    if grep -sq 'exec' /etc/jail.conf; then
        return
    fi

    jail_conf_header
}

update_freebsd() {
    tell_status "updating FreeBSD with security patches"

    # remove 'src'
    sed -i .bak -e 's/^Components src .*/Components world kernel/' /etc/freebsd-update.conf
    freebsd-update fetch install

    tell_status "updating FreeBSD pkg collection"
    pkg update || exit

    tell_status "updating FreeBSD ports tree"
    portsnap fetch update || portsnap fetch extract
}

plumb_jail_nic()
{
    if [ "$JAIL_NET_INTERFACE" = "lo1" ]; then
        sysrc cloned_interfaces=lo1
        local _missing;
        _missing=$(ifconfig lo1 2>&1 | grep 'does not exist')
        if [ -n "$_missing" ]; then
            echo "creating interface lo1"
            ifconfig lo1 create || exit
        fi
    fi
}

update_host() {
    update_freebsd
    update_host_ntpd
    update_syslogd
    update_sendmail
    constrain_sshd_to_host
    check_global_listeners
    add_jail_nat
    enable_jails
    install_jailmanage
    plumb_jail_nic
    echo; echo "Success! Your host is ready to install Mail Toaster 6!"; echo
}

update_host
