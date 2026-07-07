#!/bin/bash
# This script creates a virtual network suitable for learning about networking
# created by dennis simpson 2023, all rights reserved

source /etc/os-release

if [ ! -f $(dirname "$0")/comp2137-funcs.sh ]; then
  echo "Retrieving script library file"
  if ! wget -q -O $(dirname "$0")/comp2137-funcs.sh https://github.com/zonzorp/COMP2137/raw/main/comp2137-funcs.sh; then
    cat <<EOF
You need the comp2137-funcs.sh file from https://github.com/zonzorp/COMP2137/raw/main/comp2137-funcs.sh in order to use this script. Automatic retrieval of the file has failed. Are we online?
EOF
    exit 1
  fi
fi
source $(dirname "$0")/comp2137-funcs.sh

sudo-check

snap list lxd 2>/dev/null && error-exit "This script is not designed to run with lxd, use a VM which has never had any containers yet"

lannetnum="192.168.16"
mgmtnetnum="172.16.1"
bridgeintf=incusbr0
lanintf=lan
mgmtintf=mgmt
prefix=server
nets1037=false
startinghostnum=241
remoteadmin="remoteadmin"
numcontainers=1
puppetinstall=no
verbose=false

# save command for re-execution if necessary
commandline="$0 $@"

# allow choices on the command line
while [ $# -gt 0 ]; do
    case "$1" in
        --help | -h )
            echo "
Usage: $(basename "$0") [-h | --help] [--fresh] [--prefix targetnameprefix] [--user remoteadminaccountname] [--lannet A.B.C] [--mgmtnet A.B.C] [--count N] [--hostnumbase N] [--puppetinstall] [--nets1037] [--bridgeintf ifname] [--mgmtintf ifname] [--lanintf ifname]
This script sets up a private network using containers in a Ubuntu hosting machine for educational purposes.
It has an OpenWRT router connecting the hosting OS lan to its wan interface, and 2 virtual networks called lan and mgmt on additional interfaces.
Will install and initialize incus if necessary.
Will create lan and mgmt virtual networks if necessary using host 2 on each network for the router, both using /24 mask.
Will create openwrt router with incusbr0 for WAN, lan for lan, and mgmt for private management network.
Creates target containers, named using target name prefix with the container number appended.
Creates a remote admin account with sudo privilege, no passwd access, and ssh access for the user who runs this script.
Adds host names with IP addresses to /etc/hosts inside the containers and in the hosting OS.
The hosting OS will have direct access to all the virtual networks using host number 1.
Can install Puppet tools.
Defaults
fresh:         false
prefix:        $prefix
user:          $remoteadmin
vmwarenet:     vmware dhcp assigned
lannet:        $lannetnum
mgmtnet:       $mgmtnetnum
bridgeintf:    $bridgeintf
lanintf:       $lanintf
mgmtintf:      $mgmtintf
hostnumbase:   $startinghostnum
count:         $numcontainers
nets1037:      $nets1037
puppetinstall: $puppetinstall
verbose:       $verbose
"
            exit
            ;;
        --puppetinstall )
            puppetinstall=yes
            ;;
        --verbose )
            verbose=true
            ;;
        --fresh )
	    fresh="yes"
            ;;
        --prefix )
            if [ -z "$2" ]; then
                error-exit "Need a hostname prefix for the --prefix option"
            else
                prefix="$2"
                shift
            fi
            ;;
        --user )
            if [ -z "$2" ]; then
                error-exit "Need a username for the --user option"
            else
                remoteadmin="$2"
                shift
            fi
            ;;
        --lannet )
            if [ -z "$2" ]; then
                error-exit "Need a network number in the format N.N.N for the --lannet option"
            else
                lannetnum="$2"
                shift
            fi
            ;;
        --mgmtnet )
            if [ -z "$2" ]; then
                error-exit "Need a network number in the format N.N.N for the --mgmtnet option"
            else
                mgmtnetnum="$2"
                shift
            fi
            ;;
        --count )
            if [ -z "$2" ]; then
                error-exit "Need a number for the --count option"
            else
                numcontainers="$2"
                shift
            fi
            ;;
        --hostnumbase )
            if [ -z "$2" ]; then
                error-exit "Need a number for the --hostnumbase option"
            else
                startinghostnum="$2"
                shift
            fi
            ;;
        --bridgeintf )
            if [ -z "$2" ]; then
                error-exit "Need a name for the --bridgeintf option, default is $bridgeintf"
            else
                bridgeintf="$2"
                shift
            fi
            ;;
        --lanintf )
            if [ -z "$2" ]; then
                error-exit "Need a name for the --lanintf option, default is $lanintf"
            else
                lanintf="$2"
                shift
            fi
            ;;
        --mgmtinterface )
            if [ -z "$2" ]; then
                error-exit "Need a name for the --mgmtintf option, default is $mgmtintf"
            else
                mgmtintf="$2"
                shift
            fi
            ;;
        --nets1037 )
	    nets1037=true
	    ;;
    esac
    shift
done

# Start of script task execution

# install incus if needed
incus-install-check "$USER"

# need to make sure this shell has incus groups perms
if ! id -Gn|grep -q incus-admin; then

# check if user is configured for incus groups, configure if necessary
  if ! grep -q incus: /etc/group |grep -q "$(id -un)"; then
    sudo usermod -a -G incus,incus-admin "$(id -un)"
    echo "
User '$(id -un)' added to incus and incusadmin groups.
-------WARNING-------
In order to use this new permission, a new login shell is needed.
Ubuntu GUI logout doesn't logout, 'pkill systemd' or a reboot is required to actually logout.
Please reboot this vm and run this script again to finish making the containers.
---------------------
"
  fi
  exit
fi

echo "This script performs many tasks. Please be patient"
echo "To see more about what it is doing as it does it, use the --verbose option"
echo "You may ignore any messages about Open vSwitch or dpkg-preconfigure being unable to re-open stdin"
echo "DO NOT use control-Z when this script is running."

# init incus if no incusbr0 exists yet, else get rid of old containers if fresh is requested
if ! ip a s incusbr0 >&/dev/null; then
  echoverbose "Initializing incus"
  if ! incus admin init --auto; then
    error-exit "incus init failed"
  fi
elif [ "$fresh" = "yes" ]; then
  delete-incus-containers
fi

# create lan and mgmt networks in incus
if ! ip a s $lanintf >&/dev/null; then
    incus network create $lanintf ipv4.address="$lannetnum".1/24 ipv6.address=none ipv4.dhcp=false ipv6.dhcp=false ipv4.nat=false
fi
if ! ip a s $mgmtintf >&/dev/null; then
    incus network create $mgmtintf ipv4.address="$mgmtnetnum".1/24 ipv6.address=none ipv4.dhcp=false ipv6.dhcp=false ipv4.nat=false
fi

# identify bridge interface ip address and network number
bridgeintfip=$(ip a s $bridgeintf| grep -w inet| awk '{print $2}'|sed s,/24,,)
bridgeintfnetnum=${bridgeintfip//\\.[[:digit:]]$/}
if ! valid-ip "$bridgeintfip"; then
	error-exit "Cannot find a simple single IPV4 address for $bridgeintf of hostvm in the route table. Must fix this first."
fi

# ensure hostvm has names for bridge, lan, and mgmt hostnames in hostvm's /etc/hosts
hostvmlanip="$lannetnum.1"
hostvmmgmtip="$mgmtnetnum.1"
echoverbose "Adding hostvm to /etc/hosts file if necessary"
sudo sed -i -e '/ hostvm$/d' -e '$a'"$hostvmlanip hostvm"\
            -e '/ hostvm-mgmt$/d' -e '$a'"$hostvmmgmtip hostvm-mgmt puppet"\
            -e '/ hostvm-bridge$/d' -e '$a'"$bridgeintfip hostvm-bridge" /etc/hosts

# ensure hostvm has names for openwrt bridge, lan, and mgmt hostnames in hostvm's /etc/hosts
openwrtlanip="$lannetnum.2"
openwrtmgmtip="$mgmtnetnum.2"
echoverbose "Adding openwrt to /etc/hosts file if necessary"
sudo sed -i -e '/ openwrt$/d' -e '$a'"$openwrtlanip openwrt"\
            -e '/ openwrt-mgmt$/d' -e '$a'"$openwrtmgmtip openwrt-mgmt"\
            -e '/ openwrt-wan$/d' -e '$a'"$bridgeintfip openwrt-wan" /etc/hosts

# ensure hostvm has names for openwrt bridge, lan, and mgmt networks in hostvm's /etc/networks
echoverbose "Adding bridge, lan, and mgmt networks to /etc/networks"
sudo sed -i -e '/^incus-bridge /d' -e '$a'"incus-bridge $bridgeintfnetnum"\
            -e '/^lan /d' -e '$a'"lan $lannetnum"\
            -e '/^mgmt /d' -e '$a'"mgmt $mgmtnetnum" /etc/networks

##create the router container if necessary
if ! incus info openwrt >&/dev/null ; then
    if ! incus launch images:openwrt/25.12 openwrt -n "$bridgeintf"; then
        error-exit "Failed to create openwrt container!"
    fi
    incus network attach $lanintf openwrt eth1
    incus network attach $mgmtintf openwrt eth2

    incus exec openwrt -- sh -c "echo '
config device
    option name eth1

config interface lan
    option device eth1
    option proto static
    option ipaddr $lannetnum.2
    option netmask 255.255.255.0

config device
    option name eth2

config interface private
    option device eth2
    option proto static
    option ipaddr $mgmtnetnum.2
    option netmask 255.255.255.0

' >>/etc/config/network"
    incus exec openwrt -- sed -i "/config dnsmasq/a\        list address '/loghost.home.arpa/192.168.16.4'\n        list address '/webhost.home.arpa/192.168.16.5'\n        list address '/nmshost.home.arpa/192.168.16.6'\n        list address '/proxyhost.home.arpa/192.168.16.7'\n        list address '/dbhost.home.arpa/192.168.16.8'" /etc/config/dhcp
    incus exec openwrt reboot
fi

# we want $numcontainers containers running
if [ "$nets1037" = "true" ]; then
    echo "Making NETS1037 specific containers"
    numcontainers=5
    startinghostnum=4
fi
numexisting=$(incus list -c n --format csv|grep -c "$prefix")
for (( n=0;n<numcontainers - numexisting;n++ )); do
    if [ "$nets1037" = "true" ]; then
	case "$n" in
	    0 )
	        container=loghost
		;;
	    1 )
	        container=webhost
		;;
            2 )
	        container=nmshost
		;;
            3 )
	        container=proxyhost
		;;
            4 )
	        container=dbhost
		;;
	esac
    else
        container="$prefix$((n+1))"
    fi
    containerbridgeintfip="$bridgeintfnetnum.$((n + startinghostnum))"
    containerlanip="$lannetnum.$((n + startinghostnum))"
    containermgmtip="$mgmtnetnum.$((n + startinghostnum))"
    if incus info "$container" >& /dev/null; then
      echoverbose "$container already exists"
      continue
    else
      echoverbose "Creating $container"
    fi
    if ! incus launch images:ubuntu/24.04 "$container" -n $mgmtintf; then
      error-exit "Failed to create $container container!"
    fi
    echoverbose "Configuring $container networking"
    incus network attach $lanintf "$container" eth1
    echoverbose "Waiting for $container to complete startup"
    while [ "$(incus info "$container" | grep '^Status: ')" != "Status: RUNNING" ]; do sleep 2; done
    netplanfile=$(incus exec "$container" ls /etc/netplan)
    incus exec "$container" -- sh -c "cat > /etc/netplan/$netplanfile <<EOF
network:
    version: 2
    ethernets:
        eth0:
            addresses: [$containermgmtip/24]
        eth1:
            addresses: [$containerlanip/24]
            routes:
              - to: default
                via: $lannetnum.2
            nameservers:
                addresses: [$lannetnum.2]
                search: [home.arpa, localdomain]
EOF
"
    incus exec "$container" -- bash -c '[ -d /etc/cloud ] && echo "network: {config: disabled}" > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg'
    incus exec "$container" chmod 600 /etc/netplan/"$netplanfile"
    incus exec "$container" netplan apply
    incus exec "$container" -- sh -c 'sed -i -e "/[[:space:]]'$container'\$/d" /etc/hosts'
    incus exec "$container" -- sh -c "echo '
$containerlanip $container
$containermgmtip $container-mgmt
$lannetnum.2 openwrt
$mgmtnetnum.2 openwrt-mgmt
' >>/etc/hosts"

    echoverbose "Installing openssh-server on $container"
    incus exec "$container" -- apt-get -qq install openssh-server >/dev/null
    incus exec "$container" -- sed -i -e "s/#ListenAddress 0.0.0.0/ListenAddress $containermgmtip/" /etc/ssh/sshd_config
    incus exec "$container" -- systemctl restart ssh

    echoverbose "Setting up SSH keys for $container"
    [ -d ~/.ssh ] || ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -q -N "" >/dev/null
    [ ! -f ~/.ssh/id_ed25519.pub ] && ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519 -q -N "" > /dev/null
    ssh-keygen -q -R "$container" 2>/dev/null >/dev/null
    ssh-keyscan -t ed25519 "$container" >>~/.ssh/known_hosts 2>/dev/null
    ssh-keygen -q -H >/dev/null 2>/dev/null

    echoverbose "Adding remote admin user '$remoteadmin' to $container"
    incus exec "$container" -- useradd -m -c "SSH remote admin access account" -s /bin/bash -o -u 0 "$remoteadmin"
    incus exec "$container" mkdir "/home/$remoteadmin/.ssh"
    incus exec "$container" chmod 700 "/home/$remoteadmin/.ssh"
    incus file push ~/.ssh/id_ed25519.pub "$container/home/$remoteadmin/.ssh/"
    incus exec "$container" cp "/home/$remoteadmin/.ssh/id_ed25519.pub" "/home/$remoteadmin/.ssh/authorized_keys"
    incus exec "$container" chmod 600 "/home/$remoteadmin/.ssh/authorized_keys"
    incus exec "$container" -- chown -R "$remoteadmin" "/home/$remoteadmin"

    echoverbose "Setting $container hostname"
    incus exec "$container" hostnamectl set-hostname "$container"
    echoverbose "Restarting $container"
    incus restart "$container"
    echo "Waiting for $container restart"
    while [ "$(incus info "$container" | grep '^Status: ')" != "Status: RUNNING" ]; do sleep 2; done

    echoverbose "Adding $container to /etc/hosts file if necessary"
    sudo sed -i -e "/ $container\$/d" -e "/ $container-mgmt\$/d" /etc/hosts
    sudo sed -i -e '$a'"$containerlanip $container" -e '$a'"$containermgmtip $container-mgmt" /etc/hosts

    if [ "$puppetinstall" = "yes" ]; then
        echoverbose "Adding puppet server to /etc/hosts file if necessary"
        grep -q '[[:space:]]puppet$' /etc/hosts || sudo sed -i -e '$a'"$mgmtnetnum.1 puppet" /etc/hosts
        echoverbose "Setting up for puppet8 and installing agent on $container"
        incus exec "$container" -- wget -q https://apt.puppet.com/puppet8-release-jammy.deb
        # shellcheck disable=SC2031
        incus exec "$container" -- dpkg -i puppet8-release-"$VERSION_CODENAME".deb
        incus exec "$container" -- apt-get -qq update
        echoverbose "Restarting snapd.seeded.service can take a long time, do not interrupt it"
        incus exec "$container" -- sh -c "NEEDRESTART_MODE=a apt-get -y install puppet-agent >/dev/null"
        # shellcheck disable=SC2016
        incus exec "$container" -- sed -i '$aPATH=$PATH:/opt/puppetlabs/bin' .bashrc
        incus exec "$container" -- sed -i -e "/[[:space:]]puppet\$/d" -e '$'"a$mgmtnetnum.1 puppet" /etc/hosts
        incus exec "$container" -- /opt/puppetlabs/bin/puppet ssl bootstrap &
    fi

done

if [ "$puppetinstall" = "yes" ]; then
    for ((count=0; count < 10; count++ )); do
        sleep 3
        sudo /opt/puppetlabs/bin/puppetserver ca list --all |grep -q Requested &&
            sudo /opt/puppetlabs/bin/puppetserver ca sign --all &&
            break
    done

    [ "$count" -eq 10 ] &&
        echo "Timed out waiting for certificate request(s) from containers, wait until you see the green text for certificate requests, then do" &&
        echo "sudo /opt/puppetlabs/bin/puppetserver ca sign --all"
fi
