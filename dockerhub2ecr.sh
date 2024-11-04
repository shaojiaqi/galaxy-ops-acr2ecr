#!/bin/bash

# AWS配置信息
AWS_ACCOUNT_ID="your aws id"
ECR_REGION="your ecr region"
NAMESPACE="your-namespace"
AWS_CLI_PATH="/usr/local/bin/aws"

# Docker Hub配置信息
DOCKERHUB_USERNAME="your dockerhub username"

# 检查AWS CLI是否存在
if [ ! -f "$AWS_CLI_PATH" ]; then
    echo "错误: AWS CLI 未找到在路径 $AWS_CLI_PATH" | tee -a $LOG_FILE
    echo "请检查 AWS_CLI_PATH 配置是否正确" | tee -a $LOG_FILE
    exit 1
fi

# 需要迁移的镜像列表
REPOS_AND_TAGS=(
    "nginx:1.18.0"
    "mysql:8.0"
    # 继续添加需要迁移的仓库和标签
)

# 日志文件
LOG_FILE="dockerhub2ecr_$(date +%Y%m%d_%H%M%S).log"

# 清空日志文件
> $LOG_FILE

# 登录到 Docker Hub
echo "登录 Docker Hub..." | tee -a $LOG_FILE
echo "请输入 Docker Hub 密码:"
read -s DOCKERHUB_PASSWORD
if [ -z "$DOCKERHUB_PASSWORD" ]; then
    echo "未提供密码" | tee -a $LOG_FILE
    exit 1
fi

echo $DOCKERHUB_PASSWORD | sudo docker login --username $DOCKERHUB_USERNAME --password-stdin
if [ $? -ne 0 ]; then
    echo "Docker Hub 登录失败" | tee -a $LOG_FILE
    exit 1
fi

# 登录到 AWS ECR
echo "登录 AWS ECR..." | tee -a $LOG_FILE
sudo $AWS_CLI_PATH ecr get-login-password --region $ECR_REGION | sudo docker login --username AWS --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.$ECR_REGION.amazonaws.com
if [ $? -ne 0 ]; then
    echo "AWS ECR 登录失败" | tee -a $LOG_FILE
    exit 1
fi

# 遍历每个仓库和标签
for REPO_AND_TAG in "${REPOS_AND_TAGS[@]}"; do
    IFS=":" read -r REPO TAG <<< "$REPO_AND_TAG"
    DOCKERHUB_IMAGE="$REPO:$TAG"
    ECR_REPO="$NAMESPACE/$REPO"
    ECR_IMAGE="$AWS_ACCOUNT_ID.dkr.ecr.$ECR_REGION.amazonaws.com/$ECR_REPO:$TAG"

    # 检查并创建 ECR 仓库
    echo "检查仓库 $ECR_REPO 是否存在..." | tee -a $LOG_FILE
    REPO_EXISTS=$(sudo $AWS_CLI_PATH ecr describe-repositories --repository-names $ECR_REPO --region $ECR_REGION 2>&1)
    if [[ $REPO_EXISTS == *"RepositoryNotFoundException"* ]]; then
        echo "仓库 $ECR_REPO 不存在，正在创建..." | tee -a $LOG_FILE
        CREATE_REPO_OUTPUT=$(sudo $AWS_CLI_PATH ecr create-repository --repository-name $ECR_REPO --region $ECR_REGION 2>&1)
        if [ $? -ne 0 ]; then
            echo "创建仓库 $ECR_REPO 失败" | tee -a $LOG_FILE
            echo "错误: $CREATE_REPO_OUTPUT" | tee -a $LOG_FILE
            exit 1
        else
            echo "仓库 $ECR_REPO 创建成功" | tee -a $LOG_FILE
        fi
    else
        echo "仓库 $ECR_REPO 已存在" | tee -a $LOG_FILE
    fi

    # 从 Docker Hub 拉取镜像
    echo "从 Docker Hub 拉取镜像 $DOCKERHUB_IMAGE..." | tee -a $LOG_FILE
    sudo docker pull $DOCKERHUB_IMAGE
    if [ $? -ne 0 ]; then
        echo "拉取镜像 $DOCKERHUB_IMAGE 失败" | tee -a $LOG_FILE
        exit 1
    fi

    # 标记镜像为 ECR 格式
    echo "标记镜像 $DOCKERHUB_IMAGE 为 ECR 格式..." | tee -a $LOG_FILE
    sudo docker tag $DOCKERHUB_IMAGE $ECR_IMAGE

    # 推送镜像到 ECR
    echo "推送镜像到 ECR..." | tee -a $LOG_FILE
    sudo docker push $ECR_IMAGE
    if [ $? -ne 0 ]; then
        echo "推送镜像 $ECR_IMAGE 失败" | tee -a $LOG_FILE
        exit 1
    fi

    # 验证推送是否成功
    PUSHED=$(sudo $AWS_CLI_PATH ecr describe-images --repository-name $ECR_REPO --image-ids imageTag=$TAG --region $ECR_REGION)
    if [ -z "$PUSHED" ]; then
        echo "镜像 $ECR_IMAGE 推送验证失败" | tee -a $LOG_FILE
        exit 1
    else
        echo "镜像 $ECR_IMAGE 推送成功" | tee -a $LOG_FILE
    fi

    # 清理本地镜像
    echo "清理本地镜像..." | tee -a $LOG_FILE
    sudo docker rmi $DOCKERHUB_IMAGE
    sudo docker rmi $ECR_IMAGE
done

# 清理登录凭证
echo "清理 Docker 登录信息..." | tee -a $LOG_FILE
sudo docker logout
sudo docker logout $AWS_ACCOUNT_ID.dkr.ecr.$ECR_REGION.amazonaws.com

echo "迁移完成" | tee -a $LOG_FILE