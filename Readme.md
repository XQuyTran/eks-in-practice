# Provision the cluster with Terraform
- Optional: create a object storage for Terraform backend, e.g S3 bucket
- Run command in terraform folder:
```sh
# for local backend
terraform init

# for remote backend
terraform init -backend-config="bucket=" -backend-config="key=" -backend-config="region="

# Review and apply
terraform plan -out=tfplan -var user_name=<cluster_user_name>
terraform apply -auto-approve tfplan
```
- Deploy application by applying Kubernetes manifests in k8s-manifests folder
```sh
kubectl apply -f k8s-manifests/
```
- Create an IAM role for EKS pod
- Annotate your service account with the Amazon Resource Name (ARN) of the IAM role to assume
```sh
kubectl annotate serviceaccount -n default $service_account eks.amazonaws.com/role-arn=arn:aws:iam::$account_id:role/my-role
kubectl describe serviceaccount $service_account -n default
```
# Deployment result
## Provision cluster
EKS cluster running

![EKS cluster running](./screenshots/k-get-node.png)

## Deploy application
Application deployment with service and autoscaling configured

![alt text](./screenshots/k-get-deploy.png)

Access application through browser

![elb URL](./screenshots/elb-url.png)

## IAM role for service account
IAM role ![](./screenshots/pod-iam-role.png)![](./screenshots/pod-role-trust.png)

Deploy a AWS CLI pod using the service account to list object of a S3 bucket
```sh
kubectl apply -f k8s-manifests/pod.yaml
```
AWS CLI run result

![](./screenshots/aws-s3-list.png)
## Collect logs and metrics
Get log of application

![](./screenshots/app-log.png)