#!/bin/bash
set -e

# --- CONFIGURATION ---
CLUSTER_NAME="my-eks-cluster"
ACCOUNT_ID="514005485972"
REGION="us-east-1"
KUBECONFIG_PATH="/var/lib/jenkins/workspace/cdoe/kubeconfig"

export KUBECONFIG=$KUBECONFIG_PATH

echo "=== Installing required dependencies ==="
sudo apt-get update -y
sudo apt-get install -y curl unzip

# --- AWS CLI v2 ---
if ! command -v aws &> /dev/null || [[ $(aws --version 2>&1) != *"2."* ]]; then
    echo "Installing AWS CLI v2..."
    curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
    unzip awscliv2.zip
    sudo ./aws/install --update
    rm -rf aws awscliv2.zip
fi

# --- eksctl ---
if ! command -v eksctl &> /dev/null; then
    curl --silent --location "https://github.com/weaveworks/eksctl/releases/latest/download/eksctl_$(uname -s)_amd64.tar.gz" | tar xz -C /tmp
    sudo mv /tmp/eksctl /usr/local/bin
fi

# --- kubectl ---
echo "Installing latest kubectl..."
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
sudo mv kubectl /usr/local/bin/

# --- Helm ---
if ! command -v helm &> /dev/null; then
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# --- Update kubeconfig ---
echo "=== Updating kubeconfig for EKS cluster ==="
aws eks update-kubeconfig --name $CLUSTER_NAME --region $REGION --kubeconfig $KUBECONFIG_PATH --alias $CLUSTER_NAME

# Force correct apiVersion
sed -i 's/client.authentication.k8s.io\/v1alpha1/client.authentication.k8s.io\/v1beta1/' $KUBECONFIG_PATH

# --- Verify access ---
echo "=== Verifying kubectl access ==="
kubectl get nodes || { echo "kubectl cannot access the cluster"; exit 1; }

# --- IAM OIDC ---
echo "=== Associating IAM OIDC Provider ==="
eksctl utils associate-iam-oidc-provider --cluster $CLUSTER_NAME --region $REGION --approve || true

# --- EBS CSI policy ---
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
aws iam get-policy --policy-arn $POLICY_ARN >/dev/null 2>&1 || aws iam create-policy --policy-name AmazonEBSCSIPolicy --policy-document file://ebs-csi-policy.json

# --- IAM Service Account ---
echo "=== Creating IAM Service Account for EBS CSI ==="
eksctl create iamserviceaccount \
  --cluster $CLUSTER_NAME \
  --region $REGION \
  --namespace kube-system \
  --name ebs-csi-controller-sa \
  --attach-policy-arn $POLICY_ARN \
  --approve \
  --override-existing-serviceaccounts || true

# --- Install EBS CSI Driver ---
echo "=== Installing EBS CSI Driver using Helm ==="
helm repo add aws-ebs-csi-driver https://kubernetes-sigs.github.io/aws-ebs-csi-driver
helm repo update

helm upgrade --install aws-ebs-csi-driver aws-ebs-csi-driver/aws-ebs-csi-driver \
  --namespace kube-system \
  --create-namespace \
  --set controller.serviceAccount.create=false \
  --set controller.serviceAccount.name=ebs-csi-controller-sa

echo "=== DONE! EBS CSI driver installed successfully. ==="
