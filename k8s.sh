#!/bin/bash
clear

source ./k8s.conf

k8c_play() {
	child=$1
	tput civis
	t_col=$(tput cols)
	if [[ "t_col" -gt "99" ]]
	then
		t_col="99"
	fi
	let "col=t_col-9"

	while [[ "$?" -eq "0" ]]
	do
		tput cup $2 $col
		echo -ne "|k    8c" && tput cup $2 $col
		sleep .2
		echo -ne "/k    8c" && tput cup $2 $col
		sleep .2
		echo -ne "|k    8c" && tput cup $2 $col
		sleep .2
		echo -ne "/k    8c" && tput cup $2 $col
		sleep .2
		echo -ne "\\k    8c" && tput cup $2 $col
		sleep .1
		echo -ne "\\ k   8c" && tput cup $2 $col
		sleep .1
		echo -ne "\\  k  8c" && tput cup $2 $col
		sleep .1
		echo -ne "\\   k 8c" && tput cup $2 $col
		sleep .1
		echo -ne "\\    k8c" && tput cup $2 $col
		sleep .1
		echo -ne "|        " && tput cup $2 $col
		sleep .2
		echo -ne "|    k8c" && tput cup $2 $col
		sleep .2
		echo -ne "|       " && tput cup $2 $col
		sleep .2		
		echo -ne "|    k8c" && tput cup $2 $col
		sleep .2		
		echo -ne "        " && tput cup $2 $col
		ps -P $child >/dev/null 2>&1
	done
	tput cvvis
}

style_banner() {

t_col=$(tput cols)

if [[ "t_col" -gt "99" ]]
then
	t_col="99"
fi

echo && printf "%*s\n" $(( (${#1} + $t_col) / 2)) "$1"
printf '*%.0s' $(eval "echo {1.."$(($t_col))"}") && echo

}

print_op () {

	echo -n "$1"

}

rc_stats_w () {

child=$!

IFS=';' read -sdR -p $'\E[6n' ROW COL
row="${ROW#*[}"
let "row=row-1"
t_col=$(tput cols)

if [[ "t_col" -gt "99" ]]
then
	t_col="99"
fi

let "col=t_col-9"

k8c_play $child $row
tput cup $row $col
wait $child
rcode=$?
if [[ $rcode -eq 0 ]]
then
	echo -e "\xE2\x9C\x94   PASS"
else
	echo -e "\u0394   WARN"
fi

}

rc_stats () {

child=$!

IFS=';' read -sdR -p $'\E[6n' ROW COL
row="${ROW#*[}"
let "row=row-1"
t_col=$(tput cols)

if [[ "t_col" -gt "99" ]]
then
	t_col="99"
fi

let "col=t_col-9"

k8c_play $child $row
tput cup $row $col
wait $child
rcode=$?
if [[ $rcode -eq 0 ]]
then
	echo -e "\xE2\x9C\x94   PASS"
else
	echo -e "\xE2\x9D\x8C  FAIL\n\nCan not handle this error, exiting...\n\n ERROR:\n"
	cat /tmp/k8c-error.log
	echo 
	exit 1
fi

}

#Checking lxd pakage
style_banner "Searching mandatory packages"

print_op "Checking jq binary"
dpkg -l jq >/tmp/k8c-error.log 2>&1 &
rc_stats

print_op "Checking kubectl binary"
which kubectl >/tmp/k8c-error.log 2>&1 &
rc_stats

print_op "Checking lxd binary"
dpkg -l lxd >/tmp/k8c-error.log 2>&1 &
rc_stats

print_op "Checking lxc binary"
dpkg -l lxc >/tmp/k8c-error.log 2>&1 &
rc_stats

print_op "Initializing lxd"
lxd init --auto >/tmp/k8c-error.log 2>&1 &
rc_stats

#Cleaning
style_banner "Cleaning lxc containers and proflies"

print_op "Delete lxc containers"
lxc delete --force $(lxc list -c n --format=csv) >/tmp/k8c-error.log 2>&1 &
rc_stats

print_op "Delete profiles"
for pr in $(lxc profile list -f json | jq .[].name -r)
do
	lxc profile delete $pr >/tmp/k8c-error.log 2>&1
done

rc_stats 

#Base image setup
style_banner "Creating base image"

print_op "Loading config files"
raw_values="\"lxc.apparmor.profile=unconfined\nlxc.cap.drop= \nlxc.cgroup.devices.allow=a\nlxc.mount.auto=proc:rw sys:rw\""
source ./k8s.conf >/tmp/k8c-error.log 2>&1 && \
lxc profile create k8s >/tmp/k8c-error.log 2>&1 && \
cat >> ./tmp.config  <<EOF
config:
  limits.cpu: "2"
  limits.memory: 2GB
  limits.memory.swap: "false"
  linux.kernel_modules: ip_tables,ip6_tables,nf_nat,overlay,br_netfilter
  raw.lxc: "lxc.apparmor.profile=unconfined\nlxc.cap.drop= \nlxc.cgroup.devices.allow=a\nlxc.mount.auto=proc:rw
    sys:rw"
  security.privileged: "true"
  security.nesting: "true"
description: LXD profile for Kubernetes
devices:
  eth0:
    name: eth0
    nictype: bridged
    parent: lxdbr0
    type: nic
  root:
    path: /
    pool: default
    type: disk
name: k8s
used_by: []
EOF
lxc profile edit k8s < ./tmp.config >/tmp/k8c-error.log 2>&1 && \
rm -f ./tmp.config >/tmp/k8c-error.log 2>&1 &
rc_stats

print_op "Set base profile"
lxc profile set k8s limits.cpu 2 >/tmp/k8c-error.log 2>&1 && \
lxc profile set k8s limits.memory 4GB >/tmp/k8c-error.log 2>&1 &
rc_stats

print_op "Launch base image"
lxc launch ubuntu:20.04 k8s -p k8s >/tmp/k8c-error.log 2>&1 &
rc_stats 

#Installing packages
style_banner "Installing packages in base image"

print_op "Container network status"
until [[ $(lxc list k8s -c 4 --format=csv) ]]
do
	sleep 5
done &
rc_stats

print_op "Package installation"
lxc exec k8s -- bash -c "apt update -qq && \
apt install -qq -y containerd apt-transport-https && \
mkdir /etc/containerd && \
containerd config default > /etc/containerd/config.toml && \
systemctl restart containerd && \
systemctl enable containerd && \
curl -fsSLo /usr/share/keyrings/kubernetes-archive-keyring.gpg https://packages.cloud.google.com/apt/doc/apt-key.gpg && \
echo \"deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main\" > /etc/apt/sources.list.d/kubernetes.list && \
apt update -qq && \
apt install -qq -y kubeadm=$k8s_version kubelet=$k8s_version kubectl=$k8s_version && \
kubeadm config images pull && \
echo 'KUBELET_EXTRA_ARGS=\"--fail-swap-on=false\"' > /etc/default/kubelet" >/tmp/k8c-error.log 2>&1 &
rc_stats

#Creating master nodes

if [[ $number_of_master_nodes -gt 1 ]]
then
	style_banner "Creating multi master cluster"
	print_op "Creating master profile"
	lxc profile copy k8s k8s-master >/tmp/k8c-error.log 2>&1 && \
    lxc profile set k8s-master limits.cpu $master_node_cpu >/tmp/k8c-error.log 2>&1 && \
    lxc profile set k8s-master limits.memory $master_node_memory >/tmp/k8c-error.log 2>&1 &
	rc_stats 

	print_op "Launch Load Balancer"
	lxc profile copy k8s k8s-lb >/tmp/k8c-error.log 2>&1 && \
    lxc profile set k8s-lb limits.cpu 1 >/tmp/k8c-error.log 2>&1 && \
    lxc profile set k8s-lb limits.memory 1GB >/tmp/k8c-error.log 2>&1 && \
    lxc launch ubuntu:20.04 haproxy -p k8s-lb >/tmp/k8c-error.log 2>&1 && \
    until [[ $(lxc list haproxy -c 4 --format=csv) ]]
    do
       sleep 5    
    done >/tmp/k8c-error.log 2>&1 && \
    lxc exec haproxy -- bash -c "apt update -qq && \
	apt install -qq -y haproxy && \
    echo \"frontend kubernetes-frontend
	  bind *:6443
	  mode tcp
	  option tcplog
	  default_backend kubernetes-backend

	backend kubernetes-backend
	  option httpchk GET /healthz
	  http-check expect status 200
	  mode tcp
	  option ssl-hello-chk
	  balance roundrobin\" >> /etc/haproxy/haproxy.cfg" >/tmp/k8c-error.log 2>&1 &
	rc_stats

	load_balancer_ip=$(lxc list haproxy --format=json| jq -r '.[].state.network.eth0.addresses[0].address')

	count=1
	let "number_of_master_nodes=number_of_master_nodes+1"
	while [[ $count -ne $number_of_master_nodes ]]
	do
	  	print_op "Launch master node kmaster$count"
	  	lxc copy k8s "kmaster$count" -p k8s-master >/tmp/k8c-error.log 2>&1 && \
	   	lxc start "kmaster$count" &
	   	rc_stats

	   	print_op "kmaster$count network status" 
	    until [[ $(lxc list "kmaster$count" -c 4 --format=csv) ]]
	    do
	      sleep 5
	    done &
	    rc_stats

	   	let "count=count+1" 
	done

	print_op "Updating haproxy config"
	lxc exec haproxy -- bash -c "echo \"$(lxc list kmaster --format=json| jq -r '.[]|"       server \(.name) \(.state.network.eth0.addresses[0].address):6443 check"')\" >> /etc/haproxy/haproxy.cfg && \
	systemctl restart haproxy && \
	systemctl enable haproxy" >/tmp/k8c-error.log 2>&1 & 
    rc_stats

	print_op "Bootstrap kmaster1"
    lxc exec kmaster1 -- bash -c "mknod /dev/kmsg c 1 11 && \
	echo 'mknod /dev/kmsg c 1 11' >> /etc/rc.local && \
	chmod +x /etc/rc.local && \
	systemctl start containerd && \
	kubeadm init --pod-network-cidr=10.244.0.0/16 --control-plane-endpoint $load_balancer_ip:6443 --upload-certs --ignore-preflight-errors=all && \
	mkdir /root/.kube && cp /etc/kubernetes/admin.conf /root/.kube/config && \
	kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml" >/tmp/k8c-error.log 2>&1 &
	rc_stats

	print_op "Get joining token"
	masterJoinCommand="$(lxc exec kmaster1 -- sh -c 'kubeadm token create --print-join-command 2>/tmp/k8c-error.log') --control-plane --certificate-key $(lxc exec kmaster1 -- sh -c 'kubeadm init phase upload-certs --upload-certs --one-output 2>/tmp/k8c-error.log | grep -v upload-certs') --ignore-preflight-errors=all"
	joinCommand="$(lxc exec kmaster1 -- sh -c 'kubeadm token create --print-join-command 2>/tmp/k8c-error.log') --ignore-preflight-errors=all"
	rc_stats	

	print_op "Pull config file"
	lxc file pull kmaster1/root/.kube/config ~/.kube/config >/tmp/k8c-error.log 2>&1 &
	rc_stats

	count=2
	while [[ $count -ne $number_of_master_nodes ]]
	do
	  	print_op "Bootstrap kmaster$count"
        lxc exec "kmaster$count" -- bash -c "mknod /dev/kmsg c 1 11 && \
	    echo 'mknod /dev/kmsg c 1 11' >> /etc/rc.local && \
	    chmod +x /etc/rc.local && \
	    systemctl start containerd && \
	    eval $masterJoinCommand" >/tmp/k8c-error.log 2>&1 &
	    rc_stats

	   	let "count=count+1" 
	done


elif [[ $number_of_master_nodes -eq 1 ]]
then
	style_banner "Creating single master cluster"
    print_op "Create master profile"
	lxc profile copy k8s k8s-master >/tmp/k8c-error.log 2>&1 && \
    lxc profile set k8s-master limits.cpu $master_node_cpu >/tmp/k8c-error.log 2>&1 && \
    lxc profile set k8s-master limits.memory $master_node_memory >/tmp/k8c-error.log 2>&1 &
	rc_stats 

	print_op "Launch master node"
	lxc copy k8s kmaster -p k8s-master >/tmp/k8c-error.log 2>&1 && \
	lxc start kmaster >/tmp/k8c-error.log 2>&1 &
	rc_stats 

	print_op "kmaster network status"
    until [[ $(lxc list kmaster -c 4 --format=csv) ]]
    do
	   sleep 5
    done &
    rc_stats

    print_op "Bootstrap master node"
    lxc exec kmaster -- bash -c "mknod /dev/kmsg c 1 11 && \
	echo 'mknod /dev/kmsg c 1 11' >> /etc/rc.local && \
	chmod +x /etc/rc.local && \
	systemctl start containerd && \
	kubeadm init --pod-network-cidr=10.244.0.0/16 --ignore-preflight-errors=all && \
	mkdir /root/.kube && cp /etc/kubernetes/admin.conf /root/.kube/config && \
	kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml" >/tmp/k8c-error.log 2>&1 &
	rc_stats

    print_op "Get joining token"
	joinCommand="$(lxc exec kmaster -- sh -c 'kubeadm token create --print-join-command 2>/tmp/k8c-error.log') --ignore-preflight-errors=all"
	rc_stats

    print_op "Pull config file"
	lxc file pull kmaster/root/.kube/config ~/.kube/config >/tmp/k8c-error.log 2>&1 &
	rc_stats

else
	echo "Invalid !"
	exit 1
fi

#Creating worker nodes
style_banner "Creating worker nodes"

print_op "Create worker proflie"
lxc profile copy k8s k8s-worker >/tmp/k8c-error.log 2>&1 && \
lxc profile set k8s-worker limits.cpu $worker_node_cpu >/tmp/k8c-error.log 2>&1 && \
lxc profile set k8s-worker limits.memory $worker_node_memory >/tmp/k8c-error.log 2>&1 &
rc_stats

count=0
while [[ $count -ne $number_of_worker_nodes ]]
do
  	print_op "Launch worker node kworker$count"
  	lxc copy k8s "kworker$count" -p k8s-worker >/tmp/k8c-error.log 2>&1 && \
   	lxc start "kworker$count" &
   	rc_stats

   	print_op "kworker$count network status" 
    until [[ $(lxc list "kworker$count" -c 4 --format=csv) ]]
    do
      sleep 5
    done &
    rc_stats

    print_op "Bootstrap kworker$count"
    lxc exec "kworker$count" -- bash -c "mknod /dev/kmsg c 1 11 && \
    echo 'mknod /dev/kmsg c 1 11' >> /etc/rc.local && \
    chmod +x /etc/rc.local && \
    systemctl start containerd && \
    eval $joinCommand" >/tmp/k8c-error.log 2>&1 &
	rc_stats

   	let "count=count+1" 
done

print_op "Delete base Container"
lxc delete k8s --force &
rc_stats_w