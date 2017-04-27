CLUSTER_IP=$1
ROUTING_SUFFIX=$CLUSTER_IP.nip.io
CLUSTER_USER=admin
KUBE_INCUBATOR_DIR=$GOPATH/src/github.com/kubernetes-incubator
SERVICE_CAT_REPO=https://www.github.com/jmrodri/service-catalog.git
SERVICE_CAT_DIR=$KUBE_INCUBATOR_DIR/service-catalog
APISERVER_IMG="docker.io/ansibleplaybookbundle/apiserver:latest"
CONTROLLER_MANAGER_IMG="docker.io/ansibleplaybookbundle/controller-manager:latest"
TARGET_PROJECT=foo
ASB_BRANCH=master
BUILD_CATALOG=1

sudo yum -y install etcd nmap telnet jq wget
sudo /sbin/service etcd start

oc cluster up --routing-suffix=$ROUTING_SUFFIX

# Launch oc cluster up create user with cluster root
/shared/create_cluster_user.sh $CLUSTER_USER

# Build or pull existing apiserver/controller-manager images
if [[ -n "$BUILD_CATALOG" ]]; then
  echo "============================================================"
  echo "SERVICE CATALOG: Building from source..."
  echo "============================================================"
  mkdir -p $KUBE_INCUBATOR_DIR
  git clone $SERVICE_CAT_REPO $SERVICE_CAT_DIR
  cd $SERVICE_CAT_DIR
  git checkout $SERVICE_CAT_BRANCH
  NO_DOCKER=1 make apiserver-image controller-manager-image
else
  echo "============================================================"
  echo "SERVICE CATALOG: Pulling from dockerhub..."
  echo "============================================================"
  docker pull $APISERVER_IMG
  docker pull $CONTROLLER_MANAGER_IMG
  docker tag $APISERVER_IMG apiserver:0.0.2
  docker tag $CONTROLLER_MANAGER_IMG controller-manager:0.0.2-hack
fi

# Deploy service-catalog
oc new-project service-catalog
oc process -f /shared/service-catalog.templ.yaml | oc create -f -

# TODO: This is bad. HACK: Wait until apiserver is up
# Tap into cluster events somehow?
until oc get pods | grep -qiEm1 "apiserver.*?running"; do : ; done
# Get apiserver ip address
API_SRV_IP=$(/shared/get_apiserver_ip.sh)
SERVICE_CAT_ENDPOINT="$API_SRV_IP:8081"
echo "Service Catalog Endpoint: $SERVICE_CAT_ENDPOINT"
mkdir /home/vagrant/.kube
cat /shared/kubeconfig.templ.yaml | sed "s|{{SERVICE_CATALOG_ENDPOINT}}|$SERVICE_CAT_ENDPOINT|" \
  > /home/vagrant/.kube/service-catalog.config
chown -R vagrant:vagrant /home/vagrant/.kube

## Bring up broker
sudo yum -y install python-requests
mkdir -p $GOPATH/src/github.com/fusor
cd $GOPATH/src/github.com/fusor
git clone https://github.com/fusor/ansible-service-broker.git
#pushd ansible-service-broker && git checkout $ASB_BRANCH && popd
#cd ansible-service-broker/scripts/asbcli
#pip install -r ./requirements.txt
#./asbcli up $CLUSTER_IP:8443 \
#  --cluster-user=admin --cluster-pass=admin \
#  --dockerhub-user=$DOCKERHUB_USER --dockerhub-pass=$DOCKERHUB_PASS
#
#oc project ansible-service-broker
#until oc get pods | grep -iEm1 "asb.*?running" | grep -v deploy; do : ; done
#until oc get pods | grep -iEm1 "etcd.*?running" | grep -v deploy; do : ; done
#sleep 20
#
#ASB_ROUTE=$(oc get routes | grep ansible-service-broker | awk '{print $2}')
sudo mkdir -p /etc/ansible-service-broker
sudo cp /broker/extras/mock-registry-data.yaml /etc/ansible-service-broker/mock-registry-data.yaml
sudo chmod 644 /etc/ansible-service-broker/mock-registry-data.yaml
#/broker/bin/broker  --config=/broker/etc/prod.config.yaml --scripts /broker/scripts >  /tmp/stdout-asb.log &
/broker/bin/broker  --config=/broker/etc/mock.config.yaml --scripts /broker/scripts >  /tmp/stdout-asb.log &
ASB_ROUTE="192.168.67.2:1338"
sudo echo "export ASB_ROUTE=$ASB_ROUTE" >> /etc/profile
echo "Ansible Service Broker Route: $ASB_ROUTE"
echo "Bootstrapping broker..."
curl -X POST http://localhost:1338/v2/bootstrap
echo "Successfully bootstrapped broker!"

# Resource defs
cat /shared/broker.templ.yaml | sed "s|{{ASB_ROUTE}}|$ASB_ROUTE|" \
  > /home/vagrant/broker.yaml
oc new-project $TARGET_PROJECT
cp /shared/binding.yaml /home/vagrant
cp /shared/instance.yaml /home/vagrant
chown vagrant:vagrant /home/vagrant/{binding,instance,broker}.yaml

echo "============================================================"
echo "Cluster: $CLUSTER_IP:8443"
echo "Broker User: $CLUSTER_USER"
echo "Service Catalog API Server: $SERVICE_CAT_ENDPOINT"
echo "Ansible Service Broker: $ASB_ROUTE"
echo ""
echo "\`catctl\` is an alias for kubctl using a kubeconfig that is connected"
echo "to the service catalog directly. See ~/.kube/service-catalog.config"
echo ""
echo "To log into cluster:"
echo "$ oc login $CLUSTER_IP:8443 -u $CLUSTER_USER -p $CLUSTER_USER"
echo ""
echo "To connect the broker to the catalog:"
echo "$ catctl create -f ~/broker.yaml"
echo ""
echo "Successfully setup oc completion!"
echo "============================================================"

# Setup alias to use service-catalog apiserver with kubectl
sudo cp /shared/catctl.profile.sh /etc/profile.d
cp /home/vagrant/.bash_profile /home/vagrant/bash_profile_bak
echo "source <(oc completion bash)" >> /home/vagrant/.bash_profile
