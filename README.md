# 如何使用Docker + Jenkins pipeline搭建安卓打包环境
厌倦了每次都得在不同的打包机配置Android打包环境？

厌倦了不同打包环境带来的问题？

厌倦了学习？（那就放下手机出门去大自然散散步，下面的你不用看了）

确实厌倦了，公司的项目一直是每个项目单独配一个打包机，每次配置环境都十分难受，之前一直是实体机器，后来转到了虚拟机，搭配Docker正好合适，于是乎花费了一番功夫搭建了一个基于Docker+Jenkins pipeline的打包环境。

参考的是medium上的一篇文章，大体步骤如下：
1. 安装Docker
2. 安装并运行jenkins镜像
3. 自己build一个封装了安卓sdk、jdk、python、git环境的镜像  
4. 在前一步的基础上增加安卓模拟器

我舍弃了第四步并且在第三步的基础上增加了一点修改：增加字节的**AabResGuard**和**bundletool**，方便打aab时做资源混淆和转apks测试。当然你也可以去docker hub找一个现成的镜像，更方便，比如**etlegacy/android-build**这个。

[Github项目地址 AndroidPipeline](https://github.com/linversion/AndroidPipeline)

## 安装Docker

linux上一般在命令行装即可，Docker官方和国内daoclound都提供了一键安装的脚本。
官方的一键安装方式：
```shell
curl -fsSL https://get.docker.com | bash -s docker --mirror Aliyun
```

国内daoclound一键安装命令：
```shell
curl -sSL https://get.daocloud.io/docker | sh
```

参考资料： [Linux安装Docker完整教程](https://juejin.cn/post/7125218891642437640)

### 安装并运行jenkins

安装：
```shell
docker pull jenkins/jenkins:latest
```

运行：
```shell
docker run -d -u root -v jenkins_home:/var/jenkins_home -v /var/run/docker.sock:/var/run/docker.sock -p 8080:8080 -p 50000:50000 --restart=on-failure --name jenkins jenkins/jenkins
```

- **-d** 表示运行在后台
- **-u root** 表示运行该容器在root user下
- **-v** jenkins_home:/var/jenkins_home 创建一个jenkins_home目录与容器内的/var/jenkins_home映射
- **-v /var/run/docker.sock:/var/run/docker.sock** 链接docker socket，允许容器与docker daemon通信
- **-p 8080:8080 -p 50000:50000** 端口映射，方便宿主访问到jenkins网页
- **--restart=on-failure** 遇错自动重启
- **--name jenkins jenkins/jenkins** 容器名字


容器内安装docker：
1. 进入容器环境
```shell
docker exec -u root -it jenkins bash
```

2. 安装docker 
```shell
apt-get update
apt-get install -y docker.io
```

3. 配置jenkins账号密码


## android-build镜像

编写Dockerfile配置jdk、android sdk等环境，这是最重要的一步，所以会详细展开。

[完整代码](https://github.com/linversion/AndroidPipeline/blob/main/Dockerfile.prod)

**地基**

主要是定义ANDROID_HOME、JAVA_HOME的目录，apt安装一些必要的包（如python和git）。
```shell
FROM ubuntu:22.04
# 定义android sdk目录
ENV ANDROID_HOME="opt/android-sdk"

# support amd64 and arm64
# 设置jdk环境变量
RUN JDK_PLATFORM=$(if [ "$(uname -m)" = "aarch64" ]; then echo "arm64"; else echo "amd64"; fi) && \
    echo export JDK_PLATFORM=$JDK_PLATFORM >> /etc/jdk.env && \
    echo export JAVA_HOME="/usr/lib/jvm/java-11-openjdk-$JDK_PLATFORM/" >> /etc/jdk.env && \
    echo . /etc/jdk.env >> /etc/bash.bashrc && \
    echo . /etc/jdk.env >> /etc/profile

此处省略若干代码... 
```

**Android SDK**

主要是SDK和platform tools的安装，还要解决一个liscense的问题。我装的是Android 33，因为现在基本都是targetSdk 33。

```shell
# 删除安装临时文件
RUN rm -rf /tmp/* /var/tmp/*

# 设置环境变量
ENV ANDROID_SDK_HOME="$ANDROID_HOME"
ENV PATH="$JAVA_HOME/bin:$PATH:$ANDROID_SDK_HOME/emulator:$ANDROID_SDK_HOME/tools/bin:$ANDROID_SDK_HOME/tools:$ANDROID_SDK_HOME/platform-tools:"

# Get the latest version from https://developer.android.com/studio/index.html
ENV ANDROID_SDK_TOOLS_VERSION="8512546_latest"
ENV ANDROID_CMD_DIRECTORY="$ANDROID_HOME/cmdline-tools/latest"

# 安装 Android Toolchain
RUN echo "sdk tools ${ANDROID_SDK_TOOLS_VERSION}" && \
    wget --quiet --output-document=sdk-tools.zip \
    "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_SDK_TOOLS_VERSION}.zip" && \
    mkdir --parents "$ANDROID_HOME/cmdline-tools" && \
    unzip sdk-tools.zip -d "$ANDROID_HOME/cmdline-tools" && \
    mv "$ANDROID_HOME/cmdline-tools/cmdline-tools" $ANDROID_CMD_DIRECTORY && \
    rm --force sdk-tools.zip

# Install SDKs
# The `yes` is for accepting all non-standard tool licenses. 自动接受licenses
RUN mkdir --parents "$ANDROID_HOME/.android/" && \
    echo '### User Sources for Android SDK Manager' > \
    "$ANDROID_HOME/.android/repositories.cfg" && \
    . /etc/jdk.env && \
    yes | "$ANDROID_CMD_DIRECTORY"/bin/sdkmanager --licenses > /dev/null

# 安装需要的sdk版本 android-33
# https://developer.android.com/studio/command-line/sdkmanager.html
RUN echo "platforms" && \
    . /etc/jdk.env && \
    yes | "$ANDROID_CMD_DIRECTORY"/bin/sdkmanager \
    "platforms;android-33" > /dev/null

RUN echo "platform tools" && \
    . /etc/jdk.env && \
    yes | "$ANDROID_CMD_DIRECTORY"/bin/sdkmanager \
    "platform-tools" > /dev/null

RUN echo "build tools 33" && \
    . /etc/jdk.env && \
    yes | "$ANDROID_CMD_DIRECTORY"/bin/sdkmanager \
    "build-tools;33.0.0" > /dev/null
```

安卓sdk放/opt这个目录，默认是没有写入权限的，如果你想打debug包且没有配置签名，AS会自动帮你生成一个debug.keystore，这个时候没有写入权限会导致打包报错，解决方法可以更改sdk目录或者在Dockerfile中加入生成debug.keystore的步骤。
```shell
# generate debug keystore
RUN keytool -genkey -v dname "cn=Test Android, ou=Test, o=Star Man, c=CN" -alias androiddebugkey -keyalg RSA -keysize 2048 -validity 9125 -keystore $ANDROID_HOME/.android/debug.keystore -storepass android -keypass android
```

**AabResguard和bundletool**

资源混淆可以减少安装包体积和加固app，不建议使用gradle plugin的方式引入，一是需要适配gradle版本，二是不够灵活，因此使用命令行的方式来进行混淆。下载AabResguard0.1.10和bundletool1.15.2并解压到aabresguard目录。
```shell
RUN mkdir -p $ANDROID_HOME/aabresguard
RUN curl -L https://github.com/martinloren/mvn-repo/raw/AabResGuard_0.1.10.zip -o $ANDROID_HOME/aabresguard/AabResGuard_0.1.10.zip
RUN unzip $ANDROID_HOME/aabresguard/AabResGuard_0.1.10.zip -d $ANDROID_HOME/aabresguard
RUN curl -L https://github.com/google/bundletool/release/download/1.15.2/bundletool-all-1.15.2.jar -o $ANDROID_HOME/aabresguard/bundletool.jar
```

至此，Dockerfile主要部分完成，可以开始构建镜像了，一行命令搞定。
```shell
# 我的Dockerfile为Dockerfile.prod，因此需要指定
docker build -f Dockerfile.prod -t android-build:1.0 .
```

![dockerbuild.PNG](https://p3-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/e8e7fc2a5120441487f01773a9fcff80~tplv-k3u1fbpfcp-jj-mark:0:0:0:0:q75.image#?w=1468&h=582&s=151506&e=png&b=ffffff)
build成功之后就可以通过docker run 来运行这个镜像，不过我们是配合jenkins pipeline使用，接着看pipeline怎么写。


## Jenkins pipeline
语法也比较简单，参考教程即可。

[语法参考](https://juejin.cn/post/6961577394796757006?searchId=2024040217135275518564281828036FD5)


比较重要的一步是pipeline中的agent使用docker，**镜像是我们构建的android-build:1.0。**
```shell
pipline {
    agent {
        docker { image 'android-build:1.0' }
    }
    ...
}
```
[完整代码](https://github.com/linversion/AndroidPipeline/blob/main/pipeline.sh)

构建参数我分为多个，为了灵活控制打包流程，比如设置了一个aab_obfuscate参数控制是否开启aab混淆，其它的则是常见的版本名版本号、打包类型、flavor等。
```shell
pipeline {
    parameters {
        string(name: 'version_name', defaultValue: '1.0.0', description: 'app version name')
        string(name: 'version_code', defaultValue: '1', description: 'app version code')
        choice(name: 'type', choices: 'Release\nDebug', description: 'build type')
        choice(name: 'file_type', choices: 'apk\naab', description: 'aab or apk')
        choice(name: 'flavor', choices: 'product\ndev', description: 'Dev or Product flavor')
        booleanParam(name: 'aab_obfuscate', defaultValue: true, description: '是否混淆 aab 包的资源文件')
        booleanParam(name: 'archiveArtifacts', defaultValue: false, description: '是否归档本次构建产物')
    }
}
```
环境变量设置了签名的路径，aab资源混淆的白名单路径，钉钉的webhook。
```shell
pipeline {
        environment {
        DIR = "${WORKSPACE}"
        SIGN_FILE = "$DIR/app/key/Signing.jks"
        STORE_PASS = "SixSix"
        KEY_ALIAS = "SixSix"
        KEY_PASS = "SixSix"
        AAB_RES_CONFIG_PATH = "$DIR/aab_res_guard_cfg.xml"
        WEBHOOK = "https://oapi.dingtalk.com/robot/send?access_token="
        KEYWORD = "DingdingKeyword"
    }
}
```

整个pipeline分为三个stage: Checkout、Build、Notify，言简意赅。

Checkout阶段使用了Jenkins的片段生成器生成了一段从SVN拉取代码的代码。
```shell
stage('Checkout') {
    steps{
        // svn 拉代码
        checkout([$class: 'SubversionSCM', additionalCredentials: [], excludedCommitMessages: '', excludedRegions: '', excludedRevprop: '', excludedUsers: '', filterChangelog: false, ignoreDirPropChanges: false, includedRegions: '', locations: [[cancelProcessOnExternalsFail: true, credentialsId: 'username', depthOption: 'infinity', ignoreExternalsOption: true, local: '.', remote: 'your svn repository']], quietOperation: true, workspaceUpdater: [$class: 'UpdateUpdater']])    
    }
}
```

Build阶段主要使用gradlew配合控制参数编译apk/aab、混淆aab资源、生成apks、档输出产物。
```shell
stage('Build') {
    steps {
        script {
            def taskNamePrefix = params.file_type.equals("aab") ? "bundle" : "assemble"
            def taskName = "${taskNamePrefix}${params.flavor}${params.type}"

            sh 'chmod +x ./gradlew'
            // sh 'sudo chmod +w /opt/android-sdk/.android'
            if(params.file_type.equals('aab')) {
                // 删除旧的编译产物
                sh "rm -rf $DIR/app/build/outputs/bundle/${params.flavor}${params.type}/"
            }
            // 编译
            sh "./gradlew -Dorg.gradle.daemon=true -Dorg.gradle.jvmargs=-Xmx4096m -Dfile.encoding=utf-8 :app:${taskName} -PVERSION_NAME=${params.version_name} -PVERSION_CODE=${params.version_code}
            
            if(params.file_type.equals('aab') && params.aab_obfuscate == true) {
                // 混淆资源
                def outputPath = "$DIR/app/build/outputs/bundle/${params.flavor}${params.type}/"
                def aabName = "${params.flavor}-${params.type}-${params.version_name}-${params.version_code}"

                def aabPath = "${outputPath}${aabName}.aab"
                echo "start mv aab name"
                sh "mv ${outputPath}/*.aab ${aabPath}"
                echo "finish mv aab name"
                // 混淆aab资源
                echo "开始混淆aab资源"
                sh "java -jar /opt/android-sdk/aabresguard/com/bytedance/android/aabresguard-core/0.1.10/aabresguard-core-0.1.10.jar obfuscate-bundle --bundle=${aabPath} --output=${outputPath}obfuscated-${aabName}.aab --config=${AAB_RES_CONFIG_PATH} --merge-duplicated-res=false --storeFile=${env.SIGN_FILE} --storePassword=${env.STORE_PASS} --keyAlias=${env.KEY_ALIAS} --keyPassword=${env.KEY_PASS}"
                // 构建apks
                sh "java -jar /opt/android-sdk/aabresguard/bundletool.jar build-apks --bundle ${aabPath} --output=${outputPath}/obfuscated-${aabName}.apks --ks=${env.SIGN_FILE} --ks-pass=pass:${env.STORE_PASS} --ks-key-alias=${env.KEY_ALIAS} --key-pass=pass:${env.KEY_PASS}"
                // 归档
                if(params.archiveArtifacts) {
                    archiveArtifacts artifacts: "app/build/outputs/bundle/${params.flavor}${params.type}/*.aab", fingerprint: true
                    archiveArtifacts artifacts: "app/build/outputs/bundle/${params.flavor}${params.type}/*.apks", fingerprint: true
                    archiveArtifacts artifacts: "app/build/outputs/bundle/${params.flavor}${params.type}/*.txt", fingerprint: true
                }
            }
        }
    }
}
```

Notify阶段进行钉钉通知，定义一个dingding函数，参数是通知内容，封装发送到钉钉机器人的逻辑。
```shell
import groovy.json.JsonOutput

def dingding(String msg) {
    def dingTalkMessage = JsonOutput.toJson([
        msgtype: 'text',
        text: [
            content: "${env.KEYWORD} ${msg}"
        ]
    ])
    def curlCommand = """
    curl '${env.WEBHOOK}' -H 'Content-Type: application/json' -d '${dingTalkMessage}' 
    """
    sh curlCommand
}

pipeline {
    stage('Notify') {
        steps{
            script {
                def folder = params.file_type == "apk" ? "apk" : "bundle"
                def path = params.file_type == "apk" ? "${params.flavor}/${params.type.toLowerCase()}/" : "${params.flavor}${params.type}/"
                def content = "your content"

                dingding("打包成功 \n 下载地址: ${content}")
            }
        }
    }
    post {
        failure {
            script {
                // 获取一百条日志
                def log = currentBuild.rawBuild.getLog(100)
                dingding("打包失败\n${log}")
            }
        }
    }
}
```

至此，万事俱备，只欠东风，运行一遍pipeline，也许你会遇到一个权限报错：Got permission denied while trying to connect to the Docker daemon，可参考[解决方案](https://medium.com/igorgsousa-tech/docker-in-docker-with-jenkins-permission-problem-637f45549947)。

如果你的Jenkins运行在本地，则可以安装**Docker pipeline**这个插件即可在pipeline中使用Docker容器。

运行效果：

![jenkins.PNG](https://p9-juejin.byteimg.com/tos-cn-i-k3u1fbpfcp/ec3a8b792a324a509768527d0c762b50~tplv-k3u1fbpfcp-jj-mark:0:0:0:0:q75.image#?w=844&h=279&s=18322&e=png&b=fbfbfb)

## 参考

[How to build a CI/CD Pipeline for Android with Jenkins and Docker— Part 1](https://devjorgecastro.medium.com/how-to-build-a-ci-cd-pipeline-for-android-with-jenkins-part-1-265b62b706e6)

[Evolving our Android CI to the Cloud (2/3): Dockerizing the Tasks](https://medium.com/bestsecret-tech/evolving-our-android-ci-to-the-cloud-2-3-dockerizing-the-tasks-0d0493dea77f#id_token=eyJhbGciOiJSUzI1NiIsImtpZCI6IjZmOTc3N2E2ODU5MDc3OThlZjc5NDA2MmMwMGI2NWQ2NmMyNDBiMWIiLCJ0eXAiOiJKV1QifQ.eyJpc3MiOiJodHRwczovL2FjY291bnRzLmdvb2dsZS5jb20iLCJhenAiOiIyMTYyOTYwMzU4MzQtazFrNnFlMDYwczJ0cDJhMmphbTRsamRjbXMwMHN0dGcuYXBwcy5nb29nbGV1c2VyY29udGVudC5jb20iLCJhdWQiOiIyMTYyOTYwMzU4MzQtazFrNnFlMDYwczJ0cDJhMmphbTRsamRjbXMwMHN0dGcuYXBwcy5nb29nbGV1c2VyY29udGVudC5jb20iLCJzdWIiOiIxMDc3ODQ1NzAwMzQ4MzU5NjQzMzEiLCJlbWFpbCI6InRlZGx1dnJvYmluQGdtYWlsLmNvbSIsImVtYWlsX3ZlcmlmaWVkIjp0cnVlLCJuYmYiOjE3MDkxOTI1MTIsIm5hbWUiOiJUZWQgTW9zYnkiLCJwaWN0dXJlIjoiaHR0cHM6Ly9saDMuZ29vZ2xldXNlcmNvbnRlbnQuY29tL2EvQUNnOG9jSVFfTWxGRHhaUjdaQkIyWEpMQ3JNa1d5NWJ5M214LW9FanVPMzc4Tk9BPXM5Ni1jIiwiZ2l2ZW5fbmFtZSI6IlRlZCIsImZhbWlseV9uYW1lIjoiTW9zYnkiLCJsb2NhbGUiOiJ6aC1DTiIsImlhdCI6MTcwOTE5MjgxMiwiZXhwIjoxNzA5MTk2NDEyLCJqdGkiOiJhNzA5YzRmMGJhNWEzOGQ5YzgxOTFmZTA0N2E3ZWY5ZWNiYWRmNmYyIn0.afzbxw3Aa8_q1qeT5-JbTfUjY8Pe9LN-0jcTojZ3vS0eb47tQbaZOl81w2OUAcPmOPegwIQtUZi_qlIBbzKlU7KK4-YOyLU9MSmALT6kVYuGtcDR8mba6smF8ea8djfIkRb4ejycDGBzQ8scEdKwXEWo5WVcgDocWCNc9QI3SxaRlowoOx5nxXQzbIDYlOykahZ_g3TV2GOGEIbCHatWwkFfZYhAmTcJkuEojqTfPCZOHvNt0Yali3a6MG1Y6P2UfK8QMOaagB_J3oDJmI3rNVZxZyk0Yr-C0CCakvYXyKihe42v2qxiSyXtpuVxMVMVHTPL4EGraBBWGzmqpoW0yA)
