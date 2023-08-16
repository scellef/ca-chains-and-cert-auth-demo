#!/usr/bin/env bash

function create_root_ca {
  vault secrets enable -path=pki-root pki
  vault secrets tune -max-lease-ttl=$((365*12+3))d pki-root # Max lease 12 years + 3 leap days
  vault write pki-root/config/urls \
    issuing_certificates="$VAULT_ADDR/v1/pki-root/ca" \
    crl_distribution_points="$VAULT_ADDR/v1/pki-root/crl"
  vault write -format=json pki-root/root/generate/internal \
    common_name='Vault_Root_CA' \
    issuer_name="vault-root" \
    ttl=$((365*12+3))d \
    > $workingDir/root.json
  jq -r .data.certificate < $workingDir/root.json > $workingDir/root.crt
  issue_client_cert pki-root
}

function create_intermediate_ca {
  # Arguments:
  PKI_PATH=$1     # Vault API path for secrets engine
  COMMON_NAME=$2  # Common name for Intermediate Certificate Authority
  ISSUER_PATH=$3  # Vault API path for issuing secrets engine
  ISSUER_NAME=$4  # Issuer for Intermediate Certificate Authority 
  TTL=$5          # Number of days for ICA
  
  vault secrets enable -path=$PKI_PATH pki
  vault secrets tune -max-lease-ttl=${TTL}d $PKI_PATH # Max lease 1 year
  vault write $PKI_PATH/config/urls \
    issuing_certificates="$VAULT_ADDR/v1/${PKI_PATH}/ca" \
    crl_distribution_points="$VAULT_ADDR/v1/${PKI_PATH}/crl"
  vault write -format=json $PKI_PATH/intermediate/generate/internal \
    common_name="$COMMON_NAME" \
    issuer_name="$ISSUER_NAME" \
    | jq -r '.data.csr' > $workingDir/$PKI_PATH.csr
  vault write -format=json $ISSUER_PATH/root/sign-intermediate \
    csr=@$workingDir/$PKI_PATH.csr \
    format=pem_bundle \
    ttl=${TTL}d \
    > $workingDir/$PKI_PATH.json
  jq -r .data.certificate < $workingDir/$PKI_PATH.json > $workingDir/$PKI_PATH.crt
  vault write $PKI_PATH/intermediate/set-signed certificate=@$workingDir/$PKI_PATH.crt
  add_cert_auth_role $PKI_PATH
  issue_client_cert $PKI_PATH
}

function add_cert_auth_role {
  PKI_PATH=$1
  vault write auth/cert/certs/$PKI_PATH-client certificate=@$workingDir/$PKI_PATH.crt
}

function issue_client_cert {
  PKI_PATH=$1
  vault write $PKI_PATH/roles/client allow_any_name=true
  vault write -format=json $PKI_PATH/issue/client common_name=client > $workingDir/$PKI_PATH-client.json
}


# Create namespace, working directory for chained ICAs
vault namespace create three-chained-ints
export VAULT_NAMESPACE=three-chained-ints
vault auth enable cert
mkdir -p ./$VAULT_NAMESPACE
workingDir=$VAULT_NAMESPACE

create_root_ca
create_intermediate_ca pki-int1 Vault_Intermediate_CA_1 pki-root vault-root $((365*6+2))
create_intermediate_ca pki-int2 Vault_Intermediate_CA_2 pki-int1 vault-int1 $((365*3+1))
create_intermediate_ca pki-int3 Vault_Intermediate_CA_3 pki-int2 vault-int2 $((365))

# Create namespace, working directory for separate ICAs
unset VAULT_NAMESPACE
vault namespace create three-separate-ints
export VAULT_NAMESPACE=three-separate-ints
vault auth enable cert
mkdir -p ./$VAULT_NAMESPACE
workingDir=$VAULT_NAMESPACE

create_root_ca
create_intermediate_ca pki-int1 Vault_Intermediate_CA_1 pki-root vault-root $((365*6+2))
create_intermediate_ca pki-int2 Vault_Intermediate_CA_2 pki-root vault-root $((365*3+1))
create_intermediate_ca pki-int3 Vault_Intermediate_CA_3 pki-root vault-root $((365))

unset VAULT_NAMESPACE
while : ; do read -p "Enter 'quit' to cleanup and exit: " line
  if [ $line == "quit" ] ; then
    for i in three-chained-ints three-separate-ints ; do
      vault namespace delete $i
    done
    exit 0
  fi
done
   

