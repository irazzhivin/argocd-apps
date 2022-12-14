provider "aws" {
  region = "eu-central-1"
}

data "aws_eks_cluster" "cluster" {
  name = module.eks.cluster_id
}

data "aws_eks_cluster_auth" "cluster" {
  name = module.eks.cluster_id
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.cluster.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority.0.data)
  token                  = data.aws_eks_cluster_auth.cluster.token
  #load_config_file       = false
}

data "aws_availability_zones" "available" {
}

locals {
  cluster_name = "demo-eks-cluster"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "3.14.0"

  name                 = "k8s-vpc"
  cidr                 = "172.16.0.0/16"
  azs                  = data.aws_availability_zones.available.names
  private_subnets      = ["172.16.1.0/24", "172.16.2.0/24", "172.16.3.0/24"]
  public_subnets       = ["172.16.4.0/24", "172.16.5.0/24", "172.16.6.0/24"]
  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/elb"                      = "1"
  }

  private_subnet_tags = {
    "kubernetes.io/cluster/${local.cluster_name}" = "shared"
    "kubernetes.io/role/internal-elb"             = "1"
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "16.2.0"

  cluster_name    = local.cluster_name
  cluster_version = "1.22"
  subnets         = module.vpc.private_subnets

  vpc_id      = module.vpc.vpc_id
  enable_irsa = true
  node_groups = {
    first = {
      desired_capacity = 2
      max_capacity     = 3
      min_capacity     = 1

      instance_type = "m5.large"
    }
  }

  write_kubeconfig   = false
  config_output_path = "./"

  workers_additional_policies = [aws_iam_policy.worker_policy.arn]
}

resource "aws_iam_policy" "worker_policy" {
  name        = "iam-worker-policy"
  description = "Worker policy"

  policy = file("iam-policy.json")
}

provider "helm" {
  kubernetes {
    config_path = "~/.kube/config"
  }
}

resource "kubernetes_namespace" "nginx" {
  metadata {


    name = "ingress-nginx"
  }
}


resource "helm_release" "nginx" {
  name       = "ingress-nginx"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  namespace  = "ingress-nginx"
  set {
    name  = "controller.service.type"
    value = "NodePort"
  }
}

resource "helm_release" "argocd" {
  name = "argocd"

  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  namespace        = "argocd"
  version          = "4.9.7"
  create_namespace = true

  values = [
    file("argo-cd-config.yaml")
  ]
}

#Crossplane iam
resource "aws_iam_policy" "crossplane" {
  name_prefix = "crossplane"
  policy      = data.aws_iam_policy_document.crossplane.json
}

data "aws_iam_policy_document" "crossplane" {
  statement {
    sid    = "Crossplane"
    effect = "Allow"
    actions = [
      "s3:*"
    ]
    resources = [
    "arn:aws:s3:::*"]
  }
  statement {
    sid    = "RoleController"
    effect = "Allow"
    actions = [
      "iam:GetRole",
      "iam:AttachRolePolicy",
      "iam:CreatePolicy",
      "iam:CreatePolicyVersion",
      "iam:CreateRole",
      "iam:DeletePolicy",
      "iam:DeletePolicyVersion",
      "iam:DeleteRole",
      "iam:DeleteRolePermissionsBoundary",
      "iam:DeleteRolePolicy",
      "iam:DetachRolePolicy",
      "iam:GetPolicy",
      "iam:GetPolicyVersion",
      "iam:GetRolePolicy",
      "iam:TagRole",
      "iam:TagPolicy",
      "iam:UpdateAssumeRolePolicy",
      "iam:ListAttachedRolePolicies",
      "iam:ListPolicyVersions"
    ]
    resources = [
    "*"]
  }
}

locals {
  all_eks_clusters_oidc_issuer_urls = [trimprefix(module.eks.cluster_oidc_issuer_url, "https://")]
}

module "iam_assumable_role_crossplane" {

  source                       = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  version                      = "4.7.0"
  create_role                  = true
  role_name                    = "crossplane"
  provider_urls                = local.all_eks_clusters_oidc_issuer_urls
  role_policy_arns             = [aws_iam_policy.crossplane.arn]
  oidc_subjects_with_wildcards = ["system:serviceaccount:crossplane-system:provider-aws-*"]
}



#FIRST_RUN
# aws eks --region eu-central-1 update-kubeconfig --name demo-eks-cluster
# kubectl apply -f banana.yaml
# kubectl apply -f apple.yaml
# kubectl apply -f ingress-nginx.yaml
# kubectl apply -f routes.yaml
# curl https://a0468b226803f44b3914acc62dc1e319-d9f9fdd0b6aefaa3.elb.eu-central-1.amazonaws.com/banana
# kubectl port-forward svc/argocd-server -n argocd 8080:443
# kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d