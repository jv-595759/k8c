#!/bin/bash
clear

style_banner() {

echo
printf "%*s\n" $(( (${#1} + 90) / 2)) "$1"
echo -e "********************************************************************************************\n"
}

print_op () {

	echo -n "$1"

}

rc_stats_w () {

rcode=$?
IFS=';' read -sdR -p $'\E[6n' ROW COL
row="${ROW#*[}"
let "row=row-1"
tput cup $row 90

if [[ $rcode -eq 0 ]]
then
	echo -e "\xE2\x9C\x94   PASS"
else
	echo -e "\u0394   WARN"
fi

}

rc_stats () {

rcode=$?
IFS=';' read -sdR -p $'\E[6n' ROW COL
row="${ROW#*[}"
let "row=row-1"
tput cup $row 90

if [[ $rcode -eq 0 ]]
then
	echo -e "\xE2\x9C\x94   PASS"
else
	echo -e "\xE2\x9D\x8C  FAIL\n\nCan not handle this error, exiting...\n"
	exit 1
fi

}


#Cleaning
style_banner "Cleaning lxc containers and proflies"

print_op "Delete lxc containers"
lxc delete --force $(lxc list -c n --format=csv) >/dev/null 2>&1
rc_stats

print_op "Delete profiles"
lxc profile delete k8s >/dev/null 2>&1 && \
lxc profile delete k8s-master >/dev/null 2>&1 && \
lxc profile delete k8s-worker >/dev/null 2>&1
rc_stats_w 

#Base image setup
style_banner "Creating base image"

print_op "Loading config files"
source ./k8s.conf >/dev/null 2>&1 && \
ls ./haproxy.cfg >/dev/null 2>&1 && \
lxc profile create k8s >/dev/null 2>&1 && \
lxc profile edit k8s < ./k8s-profile
rc_stats

print_op "Set base profile"
lxc profile set k8s limits.cpu 2 >/dev/null 2>&1 && \
lxc profile set k8s limits.memory 4GB >/dev/null 2>&1
rc_stats

print_op "Launch base image"
lxc launch ubuntu:20.04 k8s -p k8s >/dev/null 2>&1
rc_stats 

#Installing packages
style_banner "Installing packages in base image"

print_op "Container network status"
until [[ $(lxc list k8s -c 4 --format=csv) ]]
do
	sleep 5
done
rc_stats

print_op "Package installation"
lxc exec k8s -- bash -c "apt update -qq && \
apt install -qq -y docker.io apt-transport-https && \
systemctl restart docker && \
systemctl enable docker && \
curl -fsSLo /usr/share/keyrings/kubernetes-archive-keyring.gpg https://packages.cloud.google.com/apt/doc/apt-key.gpg && \
echo \"deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main\" > /etc/apt/sources.list.d/kubernetes.list && \
apt update -qq && \
apt install -qq -y kubeadm=$k8s_version kubelet=$k8s_version kubectl=$k8s_version && \
kubeadm config images pull && \
echo 'KUBELET_EXTRA_ARGS=\"--fail-swap-on=false\"' > /etc/default/kubelet" >/dev/null 2>&1
rc_stats

#Creating master nodes

if [[ $number_of_master_nodes -gt 1 ]]
then
	style_banner "Creating multi master cluster"
	print_op "Creating master profile"
	echo "127.0.0.1  localhost" > dns-list 2>/dev/null && \
	echo "$load_balancer_ip  api-server" >> dns-list 2>/dev/null && \
	lxc profile copy k8s k8s-master >/dev/null 2>&1 && \
    lxc profile set k8s-master limits.cpu $master_node_cpu >/dev/null 2>&1 && \
    lxc profile set k8s-master limits.memory $master_node_memory >/dev/null 2>&1
	rc_stats 

	count=0
	while [[ $count -ne $number_of_master_nodes ]]
	do
	  	print_op "Launch master node kmaster$count"
	  	lxc copy k8s "kmaster$count" -p k8s-master >/dev/null 2>&1 && \
	   	lxc start "kmaster$count"
	   	rc_stats

	   	print_op "kmaster$count network status" 
	    until [[ $(lxc list "kmaster$count" -c 4 --format=csv) ]]
	    do
	      sleep 5
	    done
	    rc_stats

	   	let "count=count+1" 
	done

	print_op "Updating hosts file"
	lxc list kmaster --format=json| jq -r '.[]|"\(.name) \(.state.network.eth0.addresses[0].address)"' >> dns-list 2>/dev/null && \
	sed -i "/kmaster/c\\" /etc/hosts 2>/dev/null && \
	sed -i "/api-server/c\\" /etc/hosts 2>/dev/null && \
	sed -i "/localhost/c\\" /etc/hosts 2>/dev/null && \
    cat dns-list >> /etc/hosts 2>/dev/null
    rc_stats

	count=0
	while [[ $count -ne $number_of_master_nodes ]]
	do
	  	print_op "Updating kmaster$count DNS records"
        lxc file push dns-list "kmaster$count"/etc/hosts >/dev/null 2>&1 
	   	rc_stats

	   	let "count=count+1" 
	done

    print_op "Updating haproxy conf"
    cp ./haproxy.cfg /etc/haproxy/haproxy.cfg 2>/dev/null && \
    sed -i "/kmaster/c\\" /etc/haproxy/haproxy.cfg 2>/dev/null && \
    sed -i "/localhost/c\\" /etc/haproxy/haproxy.cfg 2>/dev/null && \
	sed -i "/$load_balancer_ip/c\\" /etc/haproxy/haproxy.cfg 2>/dev/null && \
    while read -r line
    do
    	echo "       server $line:6443 check" >> /etc/haproxy/haproxy.cfg 2>/dev/null
    done < dns-list && \
    systemctl restart haproxy >/dev/null 2>&1 
    rc_stats

	print_op "Bootstrap kmaster0 node"
    lxc exec kmaster0 -- bash -c "mknod /dev/kmsg c 1 11 && \
	echo 'mknod /dev/kmsg c 1 11' >> /etc/rc.local && \
	chmod +x /etc/rc.local && \
	kubeadm init --pod-network-cidr=10.244.0.0/16 --control-plane-endpoint $load_balancer_dns:$load_balancer_port --upload-certs --ignore-preflight-errors=all && \
	mkdir /root/.kube && cp /etc/kubernetes/admin.conf /root/.kube/config && \
	kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml" >/dev/null 2>&1
	rc_stats

	print_op "Get joining token"
	masterJoinCommand="$(lxc exec kmaster0 -- sh -c 'kubeadm token create --print-join-command 2>/dev/null') --control-plane --certificate-key $(lxc exec kmaster0 -- sh -c 'kubeadm init phase upload-certs --upload-certs --one-output 2>/dev/null | grep -v upload-certs') --ignore-preflight-errors=all"
	joinCommand="$(lxc exec kmaster0 -- sh -c 'kubeadm token create --print-join-command 2>/dev/null') --ignore-preflight-errors=all"
	rc_stats	

	print_op "Pull config file"
	lxc file pull kmaster0/root/.kube/config ~/.kube/config >/dev/null 2>&1
	rc_stats

	count=1
	while [[ $count -ne $number_of_master_nodes ]]
	do
	  	print_op "Bootstrap kmaster$count"
        lxc exec "kmaster$count" -- bash -c "mknod /dev/kmsg c 1 11 && \
	    echo 'mknod /dev/kmsg c 1 11' >> /etc/rc.local && \
	    chmod +x /etc/rc.local && \
	    eval $masterJoinCommand" >/dev/null 2>&1
	    rc_stats

	   	let "count=count+1" 
	done


elif [[ $number_of_master_nodes -eq 1 ]]
then
	style_banner "Creating single master cluster"
    print_op "Create master profile"
	lxc profile copy k8s k8s-master >/dev/null 2>&1 && \
    lxc profile set k8s-master limits.cpu $master_node_cpu >/dev/null 2>&1 && \
    lxc profile set k8s-master limits.memory $master_node_memory >/dev/null 2>&1
	rc_stats 

	print_op "Launch master node"
	lxc copy k8s kmaster -p k8s-master >/dev/null 2>&1 && \
	lxc start kmaster >/dev/null 2>&1
	rc_stats 

	print_op "kmaster network status"
    until [[ $(lxc list kmaster -c 4 --format=csv) ]]
    do
	   sleep 5
    done
    rc_stats

    print_op "Bootstrap master node"
    lxc exec kmaster -- bash -c "mknod /dev/kmsg c 1 11 && \
	echo 'mknod /dev/kmsg c 1 11' >> /etc/rc.local && \
	chmod +x /etc/rc.local && \
	kubeadm init --pod-network-cidr=10.244.0.0/16 --ignore-preflight-errors=all && \
	mkdir /root/.kube && cp /etc/kubernetes/admin.conf /root/.kube/config && \
	kubectl apply -f https://raw.githubusercontent.com/coreos/flannel/master/Documentation/kube-flannel.yml" >/dev/null 2>&1
	rc_stats

    print_op "Get joining token"
	joinCommand="$(lxc exec kmaster -- sh -c 'kubeadm token create --print-join-command 2>/dev/null') --ignore-preflight-errors=all"
	rc_stats

    print_op "Pull config file"
	lxc file pull kmaster/root/.kube/config ~/.kube/config >/dev/null 2>&1
	rc_stats

else
	echo "Invalid !"
	exit 1
fi

#Creating worker nodes
style_banner "Creating worker nodes"

print_op "Create worker proflie"
lxc profile copy k8s k8s-worker >/dev/null 2>&1 && \
lxc profile set k8s-worker limits.cpu $worker_node_cpu >/dev/null 2>&1 && \
lxc profile set k8s-worker limits.memory $worker_node_memory >/dev/null 2>&1
rc_stats

count=0
while [[ $count -ne $number_of_worker_nodes ]]
do
  	print_op "Launch worker node kworker$count"
  	lxc copy k8s "kworker$count" -p k8s-worker >/dev/null 2>&1 && \
   	lxc start "kworker$count"
   	rc_stats

   	print_op "kworker$count network status" 
    until [[ $(lxc list "kworker$count" -c 4 --format=csv) ]]
    do
      sleep 5
    done
    rc_stats
    
    print_op "Add DNS in kworker$count"
    lxc exec "kworker$count" -- bash -c "echo $load_balancer_ip  $load_balancer_dns >> /etc/hosts" >/dev/null 2>&1
    rc_stats

    print_op "Bootstrap kworker$count"
    lxc exec "kworker$count" -- bash -c "mknod /dev/kmsg c 1 11 && \
    echo 'mknod /dev/kmsg c 1 11' >> /etc/rc.local && \
    chmod +x /etc/rc.local && \
    eval $joinCommand" >/dev/null 2>&1
	rc_stats

   	let "count=count+1" 
done

print_op "Delete base Container"
lxc delete k8s --force
rc_stats_w