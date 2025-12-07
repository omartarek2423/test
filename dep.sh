#!/bin/bash
set -e

# --- CONFIGURATION ---
CLUSTER_NAME="my-eks-cluster"
ACCOUNT_ID="514005485972"
REGION="us-east-1"
KUBECONFIG_PATH="./kubeconfig"

echo "=== Installing dependencies ==="
sudo apt-get update -y
sudo apt-get install -y curl unzip awscli

echo "=== Installing eksctl if missing ==="
if ! command -v eksctl &> /dev/null; then
    curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
    sudo mv /tmp/eksctl /usr/local/bin
fi

echo "=== Installing Helm if missing ==="
if ! command -v helm &> /dev/null; then
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

echo "=== Installing latest kubectl ==="
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/

echo "=== Updating kubeconfig for EKS cluster ==="
aws eks update-kubeconfig --name $CLUSTER_NAME --region $REGION --kubeconfig $KUBECONFIG_PATH --alias $CLUSTER_NAME

# Force the correct apiVersion for kubectl authentication plugin
sed -i 's/client.authentication.k8s.io\/v1alpha1/client.authentication.k8s.io\/v1beta1/' $KUBECONFIG_PATH
export KUBECONFIG=$KUBECONFIG_PATH

echo "=== Associating IAM OIDC Provider ==="
eksctl utils associate-iam-oidc-provider --cluster $CLUSTER_NAME --region $REGION --approve || true

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

if ! aws iam get-policy --policy-arn $POLICY_ARN >/dev/null 2>&1; then
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
  --override-existing-serviceaccounts || true

echo "=== Installing EBS CSI Driver using Helm ==="
helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver
helm repo update

helm upgrade --install aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver \
  --namespace kube-system \
  --create-namespace \
  --set controller.serviceAccount.create=false \
  --set controller.serviceAccount.name=ebs-csi-controller-sa

echo "=== DONE! EBS CSI driver installed successfully. ==="
