# 阶段 1:编译(里面自动跑 mvn package,workflow 里就不用单独构建 jar 了)
FROM maven:3.9-eclipse-temurin-17 AS build
WORKDIR /app
COPY pom.xml .
RUN mvn -B dependency:go-offline -q    # 提前下载依赖,利用层缓存
COPY src ./src
RUN mvn -B package -DskipTests         # 测试已在 CI 跑过,这里跳过避免重复

# 阶段 2:运行(更小的 JRE 镜像)
FROM eclipse-temurin:17-jre
WORKDIR /app
COPY --from=build /app/target/*.jar app.jar
EXPOSE 8080                            # 改成你 application.yml 里的端口
ENTRYPOINT ["java", "-jar", "app.jar"]