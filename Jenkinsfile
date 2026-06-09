pipeline {
    agent any
    environment {
        APP_NAME = 'votingapp'
    }
    stages {
        stage('Build') {
            steps {
                 dir('app') {
                    git url: 'https://github.com/curious-kemi/VotingApp.git', branch: 'main'
                    sh 'mvn package'
                }
            }
        }

       /* stage ('Security Scan') {
            steps {
                sh 'checkov -d .'
                sh 'detect-secrets scan --baseline .secrets.baseline'
                sh 'tflint --init --chdir=terraform/'
                sh 'tflint --chdir=terraform/'
                sh 'terraform -chdir=terraform/ fmt -check -recursive'
            }
        }*/

        stage('Plan') {
            steps {
                sh 'terraform -chdir=terraform/envs/platform plan -input=false -out=tfplan'
                sh 'terraform -chdir=terraform/envs/platform show tfplan > tfplan.txt'
                archiveArtifacts artifacts: 'tfplan.txt'
            }
        }

        stage('Approval') {
            steps {
                input message: 'Review the plan above. Do you want to apply?', ok: 'Apply'
            }
         }

        stage ('Apply') {
            
            steps {
                sh 'terraform -chdir=terraform/envs/platform apply -input=false -auto-approve tfplan'
            }
        }

        stage ('Configure') {
            steps 
            {
                withCredentials([sshUserPrivateKey(credentialsId: 'prod/ssh/ansible-key', keyFileVariable: 'KEY', usernameVariable: 'UBUNTU')]) 
                {

                sh 'ansible-playbook -i ansible/inventory/aws_ec2.yml ansible/app.yml  --private-key $KEY -u $UBUNTU  -e "jar_file=${WORKSPACE}/app/target/{APP_NAME}.jar" '
                }
            }
        }
    }
}

