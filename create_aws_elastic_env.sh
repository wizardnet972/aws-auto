#!/bin/bash
###################################################################################################
#
# This script will create an environment in AWS (Amazon Web Services) to house an elastic, autoscaling
# node.js application running in a docker container.  Required parameters are described below.
#
# COMPONENT - What this environment will contain.  Examples are a website, api, relay, etc.
# ENV - Used to indicate the environment of the ecosystem being created.  Examples are dev, qa, prod, etc.
# AWS_SG - The name of the security group you want this ecosystem to run under.  If it doesn't exist, it will be created.
# AWS_KEY_NAME - The name of your launch configuration key name.
# NOTIFY_EMAIL - The email address you want to be notified at when remarkable events occur in this ecosystem.
# AWS_DOCKER_REPO - The name of your ECR repo.  If it doesn't exist, it will be created.
# DOCKERFILE_PATH - Path to the Dockerfile definition for image creation.
# AWS_EC2_LAUNCH_CONFIG_ROLE - The role to run the Launch Configuration under (needs AmazonEC2ContainerServiceforEC2Role permissions).
# AWS_CS_ROLE - The role to run the Cluster Service under (needs AmazonEC2ContainerServiceRole permissions).
#
###################################################################################################

COMPONENT=
ENV=
AWS_SG=
AWS_KEY_NAME=
NOTIFY_EMAIL=
AWS_DOCKER_REPO=
DOCKERFILE_PATH=
AWS_EC2_LAUNCH_CONFIG_ROLE=
AWS_CS_ROLE=

while [ $# -gt 0 ]
do
    case "$1" in
        -a)  AUTO="on";;
	-c)  COMPONENT="$2"; shift;;
	-e)  ENV="$2"; shift;;
	-s)  AWS_SG="$2"; shift;;
	-k)  AWS_KEY_NAME="$2"; shift;;
	-m)  NOTIFY_EMAIL="$2"; shift;;
	-r)  AWS_DOCKER_REPO="$2"; shift;;
	-d)  DOCKERFILE_PATH="$2"; shift;;
	-l)  AWS_EC2_LAUNCH_CONFIG_ROLE="$2"; shift;;
	-n)  AWS_CS_ROLE="$2"; shift;;
	--)	shift; break;;
	-*)
	    echo >&2 \
	    "usage: $0 [-a] [-e environment] [-c component] [-k aws key name] [-m notify email] [-s aws security group] [-r aws docker repo] [-d dockerfile path] [-l aws role with ec2 access] [-n aws role with cs access]"
	    exit 1;;
	*)  break;;	# terminate while loop
    esac
    shift
done

if [ -z "$COMPONENT" ] || [ -z "$ENV" ] || [ -z "$AWS_SG" ] || [ -z "$NOTIFY_EMAIL" ] || [ -z "$AWS_EC2_LAUNCH_CONFIG_ROLE" ] || [ -z "$AWS_DOCKER_REPO" ] || [ -z "$DOCKERFILE_PATH" ] || [ -z "$AWS_KEY_NAME" ] || [ -z "$AWS_CS_ROLE" ]; then
    echo >&2 "usage: $0 [-a] [-e environment] [-c component] [-k aws key name] [-m notify email] [-s aws security group] [-r aws docker repo] [-d dockerfile path] [-l aws role with esc access] [-n aws role with cs access]"
	exit 0
fi


echo creating $ENV environment for $COMPONENT.  Auto run is $AUTO
if [ ! "$AUTO" ]
then
	echo -n "Confirm? (y/n) "
	read -n1 OKTOGO
fi

if [[ $OKTOGO =~ ^[Yy]$ ]] || [ "$AUTO" ]; 
then
	###################################################################################################
	#
	  echo "Creating the environment..."
	#
	###################################################################################################

	###################################################################################################
	#
	  echo "SSL Certificate Upload..."
	#
	###################################################################################################
	if [ "$ENV" = "prod" ]
	then
		CERT_PATH=/opt/letsencrypt/$COMPONENT/certs/$COMPONENT.streamhammer.io
	else
		CERT_PATH=/opt/letsencrypt/$COMPONENT/certs/$COMPONENT-$ENV.streamhammer.io
	fi
	echo "Certificate path location is "$CERT_PATH
	AWS_SERVER_CERT=$(aws iam list-server-certificates --query 'ServerCertificateMetadataList[?ServerCertificateName==`cert-'$COMPONENT'-'$ENV'`].ServerCertificateName' --output text)
	if [ "$AWS_SERVER_CERT" = "cert-$COMPONENT-$ENV" ]
	then
		echo "Certificate exists.  The certificate should be updated automatically.  Run crontab -e to see if the jobs have been created."
	else 
		echo cert-$COMPONENT-$ENV
		echo "Certificate not found in AWS.  Uploading..."
		aws iam upload-server-certificate --server-certificate-name cert-$COMPONENT-$ENV --certificate-body file://$CERT_PATH/cert.pem --private-key file://$CERT_PATH/privkey.pem --certificate-chain file://$CERT_PATH/chain.pem
	fi
	echo echo "SSL Certificate Upload... DONE."

	###################################################################################################
	#
	  echo "Security Group Creation..."
	#
	###################################################################################################
	AWS_SECURITY_GROUP=$(aws ec2 describe-security-groups --group-name $AWS_SG --query 'SecurityGroups[0].GroupName' --output text)
	if [ "$AWS_SECURITY_GROUP" = "$AWS_SG" ]
	then
		echo "Security group exists, skipping creation"
	else 
		echo "Creating security group " $AWS_SG
		aws ec2 create-security-group --group-name $AWS_SG --description "www, api, app security group"
		aws ec2 authorize-security-group-ingress --group-name $AWS_SG --protocol tcp --port 80 --cidr 0.0.0.0/0
		aws ec2 authorize-security-group-ingress --group-name $AWS_SG --protocol tcp --port 22 --cidr 0.0.0.0/0
		aws ec2 authorize-security-group-ingress --group-name $AWS_SG --protocol tcp --port 8003 --cidr 0.0.0.0/0
		aws ec2 authorize-security-group-ingress --group-name $AWS_SG --protocol tcp --port 443 --cidr 0.0.0.0/0
	fi
	echo "Security Group Creation... DONE."

	###################################################################################################
	#
	  echo "Creating AWS Cluster..."
	#
	###################################################################################################
	AWS_CLUSTER=$(aws ecs list-clusters --query 'clusterArns[?contains(@,`'$COMPONENT-$ENV'`)]' --output text)
	if [ "$AWS_CLUSTER" != "" ]
	then
		echo "Cluster exists, skipping creation"
	else 
		echo "Creating cluster " $AWS_CLUSTER
		aws ecs create-cluster --cluster-name "$COMPONENT-$ENV"
	fi
	echo "Creating AWS Cluster... DONE."

	###################################################################################################
	#
	  echo "Creating AWS load balancer..."
	#
	###################################################################################################
	AWS_LOAD_BALANCER=$(aws elb describe-load-balancers --load-balancer-name lb-$COMPONENT-$ENV --query 'LoadBalancerDescriptions[0].LoadBalancerName' --output text)
	if [ "$AWS_LOAD_BALANCER" = "lb-$COMPONENT-$ENV" ]
	then
		echo "Cluster exists, skipping creation"
	else 
		echo "Creating AWS load balancer " lb-$COMPONENT-$ENV
		aws elb create-load-balancer --load-balancer-name lb-$COMPONENT-$ENV --listeners "Protocol=HTTP,LoadBalancerPort=80,InstanceProtocol=HTTP,InstancePort=80" "Protocol=SSL,LoadBalancerPort=443,InstanceProtocol=SSL,InstancePort=443,SSLCertificateId=$(aws iam list-server-certificates --query 'ServerCertificateMetadataList[?ServerCertificateName == `cert-'$COMPONENT'-'$ENV'`].Arn' --output text)" --subnets $(aws ec2 describe-subnets --query 'Subnets[].SubnetId' --output text) --security-groups $(aws ec2 describe-security-groups --group-names $AWS_SG --query 'SecurityGroups[0].GroupId' --output text)
		aws elb configure-health-check --load-balancer-name lb-$COMPONENT-$ENV --health-check Target=HTTPS:443/whosinabunker,Interval=30,UnhealthyThreshold=5,HealthyThreshold=10,Timeout=5
		openssl rsa -in $CERT_PATH/privkey.pem -pubout > $CERT_PATH/key.pub
		aws elb create-load-balancer-policy --load-balancer-name lb-$COMPONENT-$ENV --policy-name policy-lb-$COMPONENT-$ENV-pubkey --policy-type-name PublicKeyPolicyType --policy-attributes AttributeName=PublicKey,AttributeValue=$(sed '$d' < $CERT_PATH/key.pub | sed "1d"| tr -d " \t\n\r")
		aws elb create-load-balancer-policy --load-balancer-name lb-$COMPONENT-$ENV --policy-name authentication-policy-lb-$COMPONENT-$ENV --policy-type-name BackendServerAuthenticationPolicyType --policy-attributes AttributeName=PublicKeyPolicyName,AttributeValue=policy-lb-$COMPONENT-$ENV-pubkey
		aws elb set-load-balancer-policies-for-backend-server --load-balancer-name lb-$COMPONENT-$ENV --instance-port 443 --policy-names authentication-policy-lb-$COMPONENT-$ENV
		echo "Update your DNS records and create a CNAME record for the domain this load balancer is servicing.  The public IP for this load balancer is: "
		echo $(aws elb describe-load-balancers --load-balancer-name lb-$COMPONENT-$ENV --query 'LoadBalancerDescriptions[0].DNSName' --output text)
	fi
	echo "Creating AWS load balancer... DONE."

	###################################################################################################
	#
	  echo "Creating AWS IAM Roles..."
	#
	###################################################################################################
	echo "Creating AWS EC2 IAM Role..."
	AWS_IAM_ROLE=$(aws iam list-roles --query 'Roles[?RoleName==`'$AWS_EC2_LAUNCH_CONFIG_ROLE'`].RoleName' --output text)
	if [ "$AWS_IAM_ROLE" = "$AWS_EC2_LAUNCH_CONFIG_ROLE" ]
	then
		echo "IAM EC2 Role exists, skipping creation"
	else 
		echo "Creating IAM Role " $AWS_EC2_LAUNCH_CONFIG_ROLE
		aws iam create-role --role-name $AWS_EC2_LAUNCH_CONFIG_ROLE --assume-role-policy-document "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"ecs.amazonaws.com\"},\"Action\":\"sts:AssumeRole\"}]}"
		aws iam attach-role-policy --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role --role-name $AWS_EC2_LAUNCH_CONFIG_ROLE
		aws iam create-instance-profile --instance-profile-name $AWS_EC2_LAUNCH_CONFIG_ROLE
		aws iam add-role-to-instance-profile --instance-profile-name $AWS_EC2_LAUNCH_CONFIG_ROLE --role-name $AWS_EC2_LAUNCH_CONFIG_ROLE
	fi
	echo "Creating AWS EC2 IAM Role... DONE."

	echo "Creating AWS CS IAM Role..."
	AWS_IAM_CS_ROLE=$(aws iam list-roles --query 'Roles[?RoleName==`'$AWS_CS_ROLE'`].RoleName' --output text)
	if [ "$AWS_IAM_CS_ROLE" = "$AWS_CS_ROLE" ]
	then
		echo "IAM CS Role exists, skipping creation"
	else 
		echo "Creating IAM Role " $AWS_CS_ROLE
		aws iam create-role --role-name $AWS_CS_ROLE --assume-role-policy-document "{\"Version\":\"2008-10-17\",\"Statement\":[{\"Sid\":\"\",\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"ecs.amazonaws.com\"},\"Action\":\"sts:AssumeRole\"}]}"
		aws iam attach-role-policy --policy-arn arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceRole --role-name $AWS_CS_ROLE
		aws iam create-instance-profile --instance-profile-name $AWS_CS_ROLE
		aws iam add-role-to-instance-profile --instance-profile-name $AWS_CS_ROLE --role-name $AWS_CS_ROLE
	fi
	echo "Creating AWS EC2 IAM Role... DONE."
	echo "Creating AWS IAM Roles... DONE."

	###################################################################################################
	#
	  echo "Creating AWS Launch Configuration..."
	#
	###################################################################################################
	AWS_LAUNCH_CONFIG=$(aws autoscaling describe-launch-configurations --query 'LaunchConfigurations[?LaunchConfigurationName==`lc-'$COMPONENT'-'$ENV'`].LaunchConfigurationName' --output text)
	if [ "$AWS_LAUNCH_CONFIG" = "lc-$COMPONENT-$ENV" ]
	then
		echo "Launch Configuration exists, skipping creation"
	else 
		echo "Creating Launch Configuration lc-"$COMPONENT-$ENV
		printf '%s\n' '#!/bin/bash' ' ' 'echo ECS_CLUSTER='$COMPONENT'-'$ENV' > /etc/ecs/ecs.config' > /tmp/lcuserdata
		#aws autoscaling create-launch-configuration --launch-configuration-name lc-$COMPONENT-$ENV --image-id ami-181cd678 --instance-type t2.micro --iam-instance-profile $(aws iam get-instance-profile --instance-profile-name $AWS_EC2_LAUNCH_CONFIG_ROLE --query 'InstanceProfile.Arn' --output text) --user-data file:///tmp/lcuserdata --key-name $AWS_KEY_NAME --security-groups $(aws ec2 describe-security-groups --group-names $AWS_SG --query 'SecurityGroups[0].GroupId' --output text) --instance-monitoring Enabled=false --block-device-mappings "[{\"DeviceName\":\"/dev/xvda\",\"Ebs\":{\"VolumeSize\":8,\"DeleteOnTermination\":false,\"VolumeType\":\"gp2\"}},{\"DeviceName\":\"/dev/xvdcz\",\"Ebs\":{\"VolumeSize\":22,\"DeleteOnTermination\":true,\"VolumeType\":\"gp2\"}}]"
		aws autoscaling create-launch-configuration --launch-configuration-name lc-$COMPONENT-$ENV --image-id ami-181cd678 --instance-type t2.micro --iam-instance-profile $AWS_EC2_LAUNCH_CONFIG_ROLE --user-data file:///tmp/lcuserdata --key-name $AWS_KEY_NAME --security-groups $(aws ec2 describe-security-groups --group-names $AWS_SG --query 'SecurityGroups[0].GroupId' --output text) --instance-monitoring Enabled=false --block-device-mappings "[{\"DeviceName\":\"/dev/xvda\",\"Ebs\":{\"VolumeSize\":8,\"DeleteOnTermination\":false,\"VolumeType\":\"gp2\"}},{\"DeviceName\":\"/dev/xvdcz\",\"Ebs\":{\"VolumeSize\":22,\"DeleteOnTermination\":true,\"VolumeType\":\"gp2\"}}]"
		rm -f /tmp/lcuserdata	
	fi
	echo "Creating AWS Launch Configuration... DONE."

	###################################################################################################
	#
	  echo "Creating AWS Auto Scaling Group..."
	#
	###################################################################################################
	AWS_AUTO_SCALING_GROUP=$(aws autoscaling describe-auto-scaling-groups --query 'AutoScalingGroups[?AutoScalingGroupName==`asg-'$COMPONENT'-'$ENV'`].'AutoScalingGroupName --output text)
	if [ "$AWS_AUTO_SCALING_GROUP" = "asg-$COMPONENT-$ENV" ]
	then
		echo "Auto Scaling Group exists, skipping creation"
	else 
		echo "Creating Launch Configuration asg-"$COMPONENT-$ENV
		aws sns subscribe --topic-arn $(aws sns create-topic --name topic-asg-$COMPONENT-$ENV-notify --output text) --protocol email --notification-endpoint $NOTIFY_EMAIL
		aws autoscaling create-auto-scaling-group --auto-scaling-group-name asg-$COMPONENT-$ENV --launch-configuration-name lc-$COMPONENT-$ENV --load-balancer-names lb-$COMPONENT-$ENV --health-check-type EC2 --health-check-grace-period 300 --vpc-zone-identifier $(aws ec2 describe-subnets --query 'Subnets[].SubnetId' --output text | sed -e 's/\s\+/,/g') --min-size 1 --max-size 2
		aws cloudwatch put-metric-alarm --alarm-name asg-$COMPONENT-$ENV-add-capacity --metric-name CPUUtilization --namespace AWS/EC2 --statistic Average --period 120 --threshold 80 --comparison-operator GreaterThanOrEqualToThreshold --dimensions "Name=AutoScalingGroupName,Value=asg-$COMPONENT-$ENV" --evaluation-periods 2 --alarm-actions $(aws autoscaling put-scaling-policy --policy-name policy-asg-$COMPONENT-$ENV-scaleup --auto-scaling-group-name asg-$COMPONENT-$ENV --scaling-adjustment 1 --adjustment-type ChangeInCapacity --output text)
		aws cloudwatch put-metric-alarm --alarm-name asg-$COMPONENT-$ENV-remove-capacity --metric-name CPUUtilization --namespace AWS/EC2 --statistic Average --period 120 --threshold 80 --comparison-operator GreaterThanOrEqualToThreshold --dimensions "Name=AutoScalingGroupName,Value=asg-$COMPONENT-$ENV" --evaluation-periods 2 --alarm-actions $(aws autoscaling put-scaling-policy --policy-name policy-asg-$COMPONENT-$ENV-scaledown --auto-scaling-group-name asg-$COMPONENT-$ENV --scaling-adjustment -1 --adjustment-type ChangeInCapacity --output text) 
		aws autoscaling put-notification-configuration --auto-scaling-group-name asg-$COMPONENT-$ENV --topic-arn $(aws sns list-topics --query 'Topics[?contains(TopicArn, `topic-asg-'$COMPONENT'-'$ENV'-notify`)]' --output text) --notification-types $(aws autoscaling describe-auto-scaling-notification-types --query 'AutoScalingNotificationTypes[]' --output text)
	fi
	echo "Creating Auto Scaling Group... DONE."

	###################################################################################################
	#
	  echo "Creating AWS ECR Repository..."
	#
	###################################################################################################
	AWS_ECR_REPO=$(aws ecr describe-repositories --query 'repositories[?repositoryName==`'$AWS_DOCKER_REPO'`].repositoryName' --output text)
	if [ "$AWS_ECR_REPO" = "$AWS_DOCKER_REPO" ]
	then
		echo "ECR Repository exists, skipping creation"
	else 
		echo "Creating ECR Repository " $AWS_DOCKER_REPO
		aws ecr create-repository --repository-name $AWS_DOCKER_REPO
	fi
	echo "Creating AWS ECR Repository... DONE."

	###################################################################################################
	#
	  echo "Building Docker Image and Uploading to Repo..."
	#
	###################################################################################################
	AWS_DOCKER_IMAGE=$(aws ecr list-images --repository-name $AWS_DOCKER_REPO --query 'imageIds[?imageTag==`docker-'$COMPONENT'-'$ENV'-00`].imageTag' --output text)
	if [ "$AWS_DOCKER_IMAGE" = "docker-$COMPONENT-$ENV-00" ]
	then
		echo "Docker image exists and uploaded, skipping creation"
	else 
		echo "Building Docker Image and Uploading to Repo: " docker-$COMPONENT-$ENV-00
		docker build -t docker-$COMPONENT-$ENV "$DOCKERFILE_PATH"
		$(aws ecr get-login --region us-west-2)
		REPO_URI=$(aws ecr describe-repositories --query 'repositories[?repositoryName==`'$AWS_DOCKER_REPO'`].repositoryUri' --output text)
		docker tag docker-$COMPONENT-$ENV $REPO_URI:docker-$COMPONENT-$ENV-00
		docker push $REPO_URI:docker-$COMPONENT-$ENV-00
		echo "Building Docker Image and Uploading to Repo... DONE."
	fi
	
	###################################################################################################
	#
	  echo "Run Docker Container in the ECS Cluster..."
	#
	###################################################################################################
	AWS_TASK_DEFINITION=$(aws ecs list-task-definitions --query 'taskDefinitionArns[?contains(@,`:task-definition/td-'$COMPONENT'-'$ENV'`)]' --output text)
	if [ ${#AWS_TASK_DEFINITION} != 0 ]
	then
		echo "Task Definition exists, skipping creation"
	else 
		echo "Creating Task Definition " td-$COMPONENT-$ENV
		REPO_URI=$(aws ecr describe-repositories --query 'repositories[?repositoryName==`'$AWS_DOCKER_REPO'`].repositoryUri' --output text)
		aws ecs register-task-definition --family td-$COMPONENT-$ENV --container-definitions "[{\"memory\":128,\"portMappings\":[{\"hostPort\":443,\"containerPort\":8003,\"protocol\":\"tcp\"}],\"essential\":true,\"name\":\"$COMPONENT-$ENV-container\",\"image\":\"$REPO_URI:docker-$COMPONENT-$ENV-00\",\"cpu\":0}]"
		echo "Creating Task Definition... DONE."
	fi

	AWS_SERVICE=$(aws ecs list-services --cluster $COMPONENT-$ENV --query 'serviceArns[?contains(@,`'$COMPONENT'-'$ENV'`)]' --output text)
	if [ ${#AWS_SERVICE} != 0 ]
	then
		echo "Service exists, skipping creation"
	else 
		echo "Creating Service " service-$COMPONENT-$ENV
		aws ecs create-service --service-name service-$COMPONENT-$ENV --task-definition td-$COMPONENT-$ENV --cluster $COMPONENT-$ENV --desired-count 1 --role $AWS_CS_ROLE --deployment-configuration maximumPercent=200,minimumHealthyPercent=0 --load-balancers loadBalancerName=lb-$COMPONENT-$ENV,containerName=$COMPONENT-$ENV-container,containerPort=8003
		echo "Creating Service... DONE."
	fi
fi

