#!/bin/bash

# 配置阿里云和 AWS 的相关信息
ACR_REGISTRY="registry-intl.xxxxx.aliyuncs.com"
ACR_USERNAME="your acr username"
NAMESPACE="namespace of acr"  # 指定的命名空间
AWS_ACCOUNT_ID="your aws id"
ECR_REGION="your ecr region"

# 手动指定需要迁移的仓库和标签
REPOS_AND_TAGS=(
    # "nginx:1.26.0"
    "nginx:1.18.0"
    # 继续添加需要迁移的仓库和标签
)

# 日志文件
LOG_FILE="acr2ecr_$(date +%Y%m%d_%H%M%S).log"

# 清空日志文件
> $LOG_FILE

# 登录到阿里云 ACR
echo "Logging into Alibaba Cloud ACR..." | tee -a $LOG_FILE
echo "Please enter your Alibaba Cloud ACR password:"
read -s ACR_PASSWORD
if [ -z "$ACR_PASSWORD" ]; then
    echo "No password provided" | tee -a $LOG_FILE
    exit 1
fi
echo $ACR_PASSWORD | sudo docker login --username=$ACR_USERNAME --password-stdin $ACR_REGISTRY
if [ $? -ne 0 ]; then
    echo "Failed to log into Alibaba Cloud ACR" | tee -a $LOG_FILE
    exit 1
fi

# 登录到 AWS ECR
echo "Logging into AWS ECR..." | tee -a $LOG_FILE
sudo /usr/local/bin/aws ecr get-login-password --region $ECR_REGION | sudo docker login --username AWS --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.$ECR_REGION.amazonaws.com
if [ $? -ne 0 ]; then
    echo "Failed to log into AWS ECR" | tee -a $LOG_FILE
    exit 1
fi

# 遍历每个仓库和标签
for REPO_AND_TAG in "${REPOS_AND_TAGS[@]}"; do
    IFS=":" read -r REPO TAG <<< "$REPO_AND_TAG"
    IMAGE="$NAMESPACE/$REPO:$TAG"
    ACR_IMAGE="$ACR_REGISTRY/$IMAGE"
    ECR_IMAGE="$AWS_ACCOUNT_ID.dkr.ecr.$ECR_REGION.amazonaws.com/$IMAGE"

    # 检查并创建 ECR 仓库（如果不存在）
    echo "Checking if repository $NAMESPACE/$REPO exists in ECR..." | tee -a $LOG_FILE
    REPO_EXISTS=$(sudo /usr/local/bin/aws ecr describe-repositories --repository-names $NAMESPACE/$REPO --region $ECR_REGION 2>&1)
    if [[ $REPO_EXISTS == *"RepositoryNotFoundException"* ]]; then
        echo "Repository $NAMESPACE/$REPO does not exist. Creating..." | tee -a $LOG_FILE
        CREATE_REPO_OUTPUT=$(sudo /usr/local/bin/aws ecr create-repository --repository-name $NAMESPACE/$REPO --region $ECR_REGION 2>&1)
        if [ $? -ne 0 ]; then
            echo "Failed to create repository $NAMESPACE/$REPO in ECR" | tee -a $LOG_FILE
            echo "Error: $CREATE_REPO_OUTPUT" | tee -a $LOG_FILE
            exit 1
        else
            echo "Repository $NAMESPACE/$REPO created successfully" | tee -a $LOG_FILE
        fi
    else
        echo "Repository $NAMESPACE/$REPO already exists in ECR" | tee -a $LOG_FILE
    fi

    # 从 ACR 拉取镜像
    echo "Pulling image $IMAGE from ACR..." | tee -a $LOG_FILE
    sudo docker pull $ACR_IMAGE
    if [ $? -ne 0 ]; then
        echo "Failed to pull image $IMAGE from ACR" | tee -a $LOG_FILE
        exit 1
    fi

    # 标记镜像为 ECR 格式
    echo "Tagging image $IMAGE for ECR..." | tee -a $LOG_FILE
    sudo docker tag $ACR_IMAGE $ECR_IMAGE

    # 推送镜像到 ECR
    echo "Pushing image $IMAGE to ECR..." | tee -a $LOG_FILE
    sudo docker push $ECR_IMAGE
    if [ $? -ne 0 ]; then
        echo "Failed to push image $IMAGE to ECR" | tee -a $LOG_FILE
        exit 1
    fi

    # 校验推送成功
    PUSHED=$(sudo /usr/local/bin/aws ecr describe-images --repository-name $NAMESPACE/$REPO --image-ids imageTag=$TAG --region $ECR_REGION)
    if [ -z "$PUSHED" ]; then
        echo "Image $IMAGE push verification failed" | tee -a $LOG_FILE
        exit 1
    else
        echo "Image $IMAGE pushed successfully" | tee -a $LOG_FILE
    fi

    # 删除本地镜像以节省空间
    echo "Removing local images..." | tee -a $LOG_FILE
    sudo docker rmi $ACR_IMAGE
    sudo docker rmi $ECR_IMAGE
done

echo "Migration completed successfully" | tee -a $LOG_FILE
