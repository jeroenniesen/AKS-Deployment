#params
PREFIX="DEM" #Should not exceed 3 characters
STAGE="PRD" #Should not exceed 3 characters (DEV/TST/ACC/PRD)
LOCATION="WEU" #Should not exceed 3 characters (only NEU en WEU are available)
VM_SIZE="Standard_DS2_v2" #Standard_DS2_v2 for production , Standard_B2ms for devtest
VNET_ADDRESS_SPACE=10.12.0.0/16
VNET_AKS_SUBNET=10.12.4.0/22
AKS_Version=1.18.4
DNS_LABEL=aksingress01

# define names
DEPLOY_LOCATION="WestEurope"
if [ "$LOCATION" == "WEU" ]; then
   DEPLOY_LOCATION="WestEurope"
fi

if [ "$LOCATION" == "NEU" ]; then
   DEPLOY_LOCATION="NorthEurope"
fi

echo -e "Stage: $STAGE \n" 
echo -e "Location: $DEPLOY_LOCATION \n" 
echo -e "VNET Address Space: $VNET_ADDRESS_SPACE \n" 
echo -e "VNET AKS Subnet: $VNET_AKS_SUBNET \n" 
echo -e "Kubernetes version to deploy: $AKS_Version \n"

az extension add --name aks-preview
az extension update --name aks-preview

#Construct Virtual Network Resource Group
RSG_NETWORKING_NAME="$PREFIX-$LOCATION-$STAGE-RSG-DEMO_NETWORKING-01"
az group create --location $DEPLOY_LOCATION --name $RSG_NETWORKING_NAME

# DEPLOY VNET
VNET_NAME="$PREFIX-$LOCATION-$STAGE-VNET-DEMO-01" 
VNET_AKS_SUBNETNAME="SUBNET-AKS-01"
az network vnet create -g $RSG_NETWORKING_NAME -n $VNET_NAME --address-prefix $VNET_ADDRESS_SPACE --subnet-name $VNET_AKS_SUBNETNAME --subnet-prefix $VNET_AKS_SUBNET

VNET_AKS_SUBNET_ID=$(az network vnet subnet list --resource-group $RSG_NETWORKING_NAME --vnet-name $VNET_NAME --query "[0].id" --output tsv)

#Construct Encryption Resource Group
RSG_ENCRYPTION_NAME="$PREFIX-$LOCATION-$STAGE-RSG-DEMO_ENCRYPTION-01"
az group create --location $DEPLOY_LOCATION --name $RSG_ENCRYPTION_NAME

#DEPLOY KEY VAULT
KEYVAULT_NAME="$PREFIX-$LOCATION-$STAGE-KV-INFRA"
az keyvault create --name $KEYVAULT_NAME \
                    --resource-group $RSG_ENCRYPTION_NAME \
                    --location $DEPLOY_LOCATION \
                    --enable-purge-protection true \
                    --enable-soft-delete true 

KEY_NAME="$PREFIX-ENCRYPTION-01"
az keyvault key create --name $KEY_NAME --vault-name $KEYVAULT_NAME --protection software

KEYVAULT_ID=$(az keyvault show --name $KEYVAULT_NAME --query [id] -o tsv)
KEY_URL=$(az keyvault key show --vault-name $KEYVAULT_NAME  --name $KEY_NAME  --query [key.kid] -o tsv)

#DEPLOY DISK ENCRYPTION SET
DES_NAME="$PREFIX-$LOCATION-$STAGE-DES-AKS_DEMO-01"
az disk-encryption-set create -n $DES_NAME  \
                              -l $DEPLOY_LOCATION \
                              -g $RSG_ENCRYPTION_NAME \
                              --source-vault $KEYVAULT_ID \
                              --key-url $KEY_URL

DES_IDENTITY=$(az disk-encryption-set show -n $DES_NAME  -g $RSG_ENCRYPTION_NAME --query [identity.principalId] -o tsv)
az keyvault set-policy -n $KEYVAULT_NAME \
                       -g $RSG_ENCRYPTION_NAME \
                       --object-id $DES_IDENTITY \
                       --key-permissions wrapkey unwrapkey get

DES_ID=$(az resource show -n $DES_NAME -g $RSG_ENCRYPTION_NAME --resource-type "Microsoft.Compute/diskEncryptionSets" --query [id] -o tsv)

#Construct Logging Resource Group
RSG_LOGGING_NAME="$PREFIX-$LOCATION-$STAGE-RSG-DEMO_LOGGING-01"
az group create --location $DEPLOY_LOCATION --name $RSG_LOGGING_NAME

LAW_NAME="$PREFIX-$LOCATION-$STAGE-LAN-DEMO-LOGS-01";
az monitor log-analytics workspace create --resource-group $RSG_LOGGING_NAME \
                                          --workspace-name $LAW_NAME \
                                          --location $DEPLOY_LOCATION

LAW_ID=$(az resource list -n $LAW_NAME -g $RSG_LOGGING_NAME --query [].id -o tsv)

#Construct AKS Resource Group
 RSG_AKS_NAME="$PREFIX-$LOCATION-$STAGE-RSG-DEMO_AKS-01"
 az group create --location $DEPLOY_LOCATION --name $RSG_AKS_NAME

 AKS_NAME="$PREFIX-$LOCATION-$STAGE-AKS-01"

az aks create -n $AKS_NAME \
 -g $RSG_AKS_NAME \
 --node-osdisk-diskencryptionset-id $DES_ID \
 --kubernetes-version $AKS_Version \
 --enable-addons monitoring \
 --location $DEPLOY_LOCATION \
 --network-plugin azure \
 --vnet-subnet-id $VNET_AKS_SUBNET_ID \
 --docker-bridge-address 172.17.0.1/16 \
 --dns-service-ip 10.244.0.10 \
 --service-cidr 10.244.0.0/22 \
 --workspace-resource-id $LAW_ID \
 --node-vm-size $VM_SIZE \
 --node-count 1 \
 --vm-set-type VirtualMachineScaleSets \
 --load-balancer-sku standard \
 --enable-cluster-autoscaler \
 --min-count 1 \
 --max-count 5 \
 --nodepool-name "general" \
 --generate-ssh-keys \
 --enable-managed-identity
