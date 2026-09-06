# GitHub Actions + Docker CI/CD 部署文档

> 项目:Spring Boot (`github_action`) · 镜像仓库:GHCR (`ghcr.io/gh-jsong/github_action`) · 部署目标:云服务器(Docker + docker compose)
> 效果:`git push` 到 `main` 后自动完成:测试 → 构建镜像 → 推送到 GHCR → SSH 部署到云服务器。

## 目录

1. [整体架构](#整体架构)
2. [仓库内配置文件](#仓库内配置文件)
3. [GitHub 仓库设置(Secrets)](#github-仓库设置secrets)
4. [云服务器端配置](#云服务器端配置)
5. [端到端触发链路](#端到端触发链路)
6. [常用验证 / 运维命令](#常用验证--运维命令)
7. [踩坑记录(排查要点)](#踩坑记录排查要点)

## 整体架构

```
[本地电脑] git push (main)
   → GitHub Actions (ubuntu-latest)
       ① test        : JDK17 + mvn test
       ② build-push  : docker build(多阶段) → push ghcr.io:latest / :commit-sha
       ③ deploy      : SSH 云服务器 → docker compose pull && up -d
   → 容器 myapp 启动,对外提供 8080 端口
```

特点:CI 全部在 GitHub 云端执行,**本地不需要在线、不需要公网 IP、不需要内网穿透**;唯一公网可达的环节是部署目标(云服务器)。

## 仓库内配置文件

### `.github/workflows/ci-cd.yml`

```yaml
name: CI/CD Pipeline

on:
  push:
    branches: [ main ]
    tags: [ 'v*' ]
  pull_request:
    branches: [ main ]

permissions:
  contents: read
  packages: write

env:
  IMAGE_NAME: ghcr.io/${{ github.repository }}

jobs:
  # ① CI:测试
  test:
    name: 测试
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: '17'
          cache: maven
      - run: mvn -B test

  # ② 构建镜像并推送
  build-and-push:
    name: 构建并推送镜像
    needs: test
    runs-on: ubuntu-latest
    if: github.event_name != 'pull_request'
    steps:
      - uses: actions/checkout@v4
      - name: 登录 GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - name: 构建并推送
        uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: |
            ${{ env.IMAGE_NAME }}:latest
            ${{ env.IMAGE_NAME }}:${{ github.sha }}

  # ③ 部署到云服务器
  deploy:
    name: 部署到云服务器
    needs: build-and-push
    runs-on: ubuntu-latest
    if: github.ref == 'refs/heads/main'
    steps:
      - uses: appleboy/ssh-action@v1.2.0
        with:
          host: ${{ secrets.DEPLOY_HOST }}
          username: ${{ secrets.DEPLOY_USER }}
          key: ${{ secrets.DEPLOY_KEY }}
          script: |
            cd ${{ secrets.DEPLOY_PATH }}
            docker compose pull
            docker compose up -d
            docker image prune -f
```

### `Dockerfile`

```dockerfile
# 阶段 1:编译(fat jar)
FROM maven:3.9-eclipse-temurin-17 AS build
WORKDIR /app
COPY pom.xml .
RUN mvn -B dependency:go-offline -q
COPY src ./src
RUN mvn -B package -DskipTests

# 阶段 2:运行(精简 JRE)
FROM eclipse-temurin:17-jre
WORKDIR /app
COPY --from=build /app/target/*.jar app.jar
EXPOSE 8080
ENTRYPOINT ["java", "-jar", "app.jar"]
```

### `pom.xml` 关键配置

```xml
<properties>
    <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
    <maven.compiler.source>17</maven.compiler.source>
    <maven.compiler.target>17</maven.compiler.target>
</properties>

<build>
    <plugins>
        <plugin>
            <groupId>org.springframework.boot</groupId>
            <artifactId>spring-boot-maven-plugin</artifactId>
            <version>3.4.7</version>
            <executions>
                <execution>
                    <goals><goal>repackage</goal></goals>
                </execution>
            </executions>
            <configuration>
                <mainClass>com.song.App</mainClass>
            </configuration>
        </plugin>
    </plugins>
</build>
```

> ⚠️ `no main manifest attribute` 的根因与修复:jar 必须经过 `spring-boot-maven-plugin` 的 `repackage` 才是可执行 fat jar。声明插件后**显式写 `<executions>`** 并**指定 `<mainClass>`**,不要依赖自动绑定/自动探测。

## GitHub 仓库设置(Secrets)

仓库 → `Settings → Secrets and variables → Actions`:

| Secret 名 | 用途 |
|---|---|
| `DEPLOY_HOST` | 云服务器公网 IP |
| `DEPLOY_USER` | SSH 登录用户名(如 `root`) |
| `DEPLOY_KEY` | 服务器部署私钥(**完整复制,含 BEGIN/END 两行**) |
| `DEPLOY_PATH` | 服务器 compose 目录(如 `/srv/myapp`) |
| `GITHUB_TOKEN` | GitHub 自动提供,用于登录 GHCR 推镜像(无需配置) |

> GHCR 上的镜像包默认私有:服务器要能 `docker pull`,需在仓库 Packages 里把包设为 **public**,或在服务器执行一次 `docker login ghcr.io`。

## 云服务器端配置

### 一次性准备

```bash
# 1. 安装 Docker(自带 compose 插件)
curl -fsSL https://get.docker.com | sh
sudo systemctl enable --now docker

# 2. 应用目录
sudo mkdir -p /srv/myapp
cd /srv/myapp
# 放入下面的 docker-compose.yml
```

### `/srv/myapp/docker-compose.yml`

```yaml
services:
  app:
    image: ghcr.io/gh-jsong/github_action:latest
    container_name: myapp
    restart: unless-stopped
    ports:
      - "8080:8080"
```

### SSH 部署密钥

```bash
ssh-keygen -t ed25519 -f ~/.ssh/github_deploy -N ""
cat ~/.ssh/github_deploy.pub >> ~/.ssh/authorized_keys
chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys
# 自测:ssh -i ~/.ssh/github_deploy -o StrictHostKeyChecking=no localhost echo ok
# 私钥全文:cat ~/.ssh/github_deploy → 填入 GitHub Secret: DEPLOY_KEY
```

### 安全组 / 防火墙

- **22** 端口:GitHub runner SSH 部署用
- **8080** 端口:应用对外访问

## 端到端触发链路

```
git push (main)
   → GitHub Actions test(JDK17 + mvn test)
   → build-and-push(docker buildx 多阶段 → ghcr.io:latest + :commit-sha)
   → deploy(SSH 云服务器 → docker compose pull && up -d)
   → curl http://<服务器IP>:8080/hello/{name}   # 返回 hello : xxx
```

## 常用验证 / 运维命令

```bash
# 看流水线:GitHub 仓库 → Actions 页面

# 服务器上看容器与日志
docker ps
docker logs -f myapp          # 出现 "Started App in X.XXX seconds" 即成功

# 手动重新部署(拉最新镜像并重启)
cd /srv/myapp && docker compose pull && docker compose up -d

# 健康检查
curl http://<服务器IP>:8080/hello/song
```

## 踩坑记录(排查要点)

| 现象 | 原因与解决 |
|---|---|
| workflow 报 `Unexpected value ''` (Line 1, Col 4) | 文件开头带 UTF-8 **BOM**。去掉:`sed -i '1s/^\xEF\xBB\xBF//' .github/workflows/ci-cd.yml`,或 VS Code 以无 BOM 的 UTF-8 重存 |
| Actions 报 lock file not found | 模板是 Node 的(`setup-node`+`npm`);Spring Boot 项目应换 `setup-java` + `mvn -B test` |
| Node 20 deprecation warning | `actions/checkout@v4` 等被强制跑 Node 24,只是警告,不影响;后续升级 `@v5` 可消除 |
| deploy 报 `ssh: no key found` | `DEPLOY_KEY` 私钥内容不完整(丢 BEGIN/END 头尾或换行被压成一行),重新 `cat ~/.ssh/github_deploy` 完整复制 |
| 容器 `Restarting (1)` 循环 | 用 `docker logs myapp --tail 100` 看真实报错,别只盯 `docker ps` |
| 容器日志 `no main manifest attribute, in app.jar` | 缺 `spring-boot-maven-plugin` 的 repackage,见上方 pom 关键配置 |
| 镜像更新后仍跑旧版 | 确认服务器 `docker compose pull` 成功;`docker images` 看 `latest` 的 CREATED 时间 |

---

*备注:每次 push 到 main 自动部署的是 `:latest`;打 `v*` tag 会触发流水线,可按需在 build 步骤追加 `${{ env.IMAGE_NAME }}:${{ github.ref_name }}` 做版本镜像。*
