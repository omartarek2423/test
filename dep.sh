#!/bin/bash
set -e

# --- CONFIGURATION ---
CLUSTER_NAME="my-eks-cluster"
ACCOUNT_ID="514005485972"
REGION="us-east-1"

echo "=== Updating package lists ==="
sudo apt-get update -y

echo "=== Installing required dependencies if missing ==="
# Install curl
if ! command -v curl &> /dev/null; then
    echo "curl not found. Installing..."
    sudo apt-get install curl -y
fi

# Install unzip
if ! command -v unzip &> /dev/null; then
    echo "unzip not found. Installing..."
    sudo apt-get install unzip -y
fi

# Install awscli
if ! command -v aws &> /dev/null; then
    echo "awscli not found. Installing..."
    sudo apt-get install awscli -y
fi

# Install eksctl
if ! command -v eksctl &> /dev/null; then
    echo "eksctl not found. Installing..."
    curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
    sudo mv /tmp/eksctl /usr/local/bin
fi

# Install Helm
if ! command -v helm &> /dev/null; then
    echo "Helm not found. Installing Helm..."
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# Install latest kubectl
echo "=== Installing latest kubectl ==="
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/

echo "=== Updating kubeconfig for EKS cluster ==="
aws eks update-kubeconfig --name $CLUSTER_NAME --region $REGION --kubeconfig ./kubeconfig
export KUBECONFIG=./kubeconfig

kubectl get nodes

echo "=== Associating IAM OIDC Provider ==="
eksctl utils associate-iam-oidc-provider --cluster $CLUSTER_NAME --region $REGION --approve

echo "=== Creating EBS CSI IAM policy ==="
cat <<JSON > ebs-csi-policy.json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "ec2:AttachVolume",
                "ec2:DetachVolume",
                "ec2:CreateSnapshot",
                "ec2:DeleteSnapshot",
                "ec2:DescribeAvailabilityZones",
                "ec2:DescribeInstances",
                "ec2:DescribeSnapshots",
                "ec2:DescribeTags",
                "ec2:DescribeVolumes",
                "ec2:DescribeVolumesModifications",
                "ec2:ModifyVolume"
            ],
            "Resource": "*"
        }
    ]
}
JSON

POLICY_ARN="arn:aws:iam::$ACCOUNT_ID:policy/AmazonEBSCSIPolicy"

if aws iam get-policy --policy-arn $POLICY_ARN >/dev/null 2>&1; then
    echo "Policy AmazonEBSCSIPolicy already exists. Skipping creation."
else
    aws iam create-policy --policy-name AmazonEBSCSIPolicy --policy-document file://ebs-csi-policy.json
fi

echo "=== Creating IAM Service Account for EBS CSI ==="
eksctl create iamserviceaccount \
  --cluster $CLUSTER_NAME \
  --region $REGION \
  --namespace kube-system \
  --name ebs-csi-controller-sa \
  --attach-policy-arn $POLICY_ARN \
  --approve \
  --override-existing-serviceaccounts

echo "=== Installing EBS CSI Driver using Helm ==="
helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver
helm repo update

helm upgrade --install aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver \
  --namespace kube-system \
  --create-namespace \
  --set controller.serviceAccount.create=false \
  --set controller.serviceAccount.name=ebs-csi-controller-sa

echo "=== DONE! EBS CSI driver installed successfully. ==="
