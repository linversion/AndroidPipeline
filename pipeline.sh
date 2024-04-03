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
    agent {
        docker { image 'android-build:1.0' }
    }
    parameters {
        string(name: 'version_name', defaultValue: '1.0.3', description: 'app version name')
        string(name: 'version_code', defaultValue: '3', description: 'app version code')
        choice(name: 'type', choices: 'Release\nDebug', description: 'build type')
        choice(name: 'file_type', choices: 'apk\naab', description: 'aab or apk')
        choice(name: 'flavor', choices: 'product\ndev', description: 'Dev or Product flavor')
        booleanParam(name: 'aab_obfuscate', defaultValue: true, description: '是否混淆 aab 包的资源文件')
        booleanParam(name: 'archiveArtifacts', defaultValue: false, description: '是否归档本次构建产物')
    }
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
    stages {
        stage('Checkout') {
            steps{
                // svn 拉代码
                checkout([$class: 'SubversionSCM', additionalCredentials: [], excludedCommitMessages: '', excludedRegions: '', excludedRevprop: '', excludedUsers: '', filterChangelog: false, ignoreDirPropChanges: false, includedRegions: '', locations: [[cancelProcessOnExternalsFail: true, credentialsId: 'username', depthOption: 'infinity', ignoreExternalsOption: true, local: '.', remote: 'http://svn']], quietOperation: true, workspaceUpdater: [$class: 'UpdateUpdater']])    
            }
        }
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
                    sh "./gradlew -Dorg.gradle.daemon=true -Dorg.gradle.jvmargs=-Xmx4096m -Dfile.encoding=utf-8 :app:${taskName} -PVERSION_NAME=${params.version_name} -PVERSION_CODE=${params.version_code}"
                    
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
    }
    post {
        failure {
            script {
                def log = currentBuild.rawBuild.getLog(100)
                dingding("打包失败\n${log}")
            }
        }
    }
}