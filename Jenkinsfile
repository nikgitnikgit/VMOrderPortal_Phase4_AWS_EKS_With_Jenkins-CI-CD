// Jenkinsfile — VM Order Portal Phase 4 CI/CD Pipeline
// Runs entirely inside EKS: agent pods with BuildKit (rootless), Trivy,
// and a tools sidecar. No Docker daemon, no privileged containers.
//
// Values that come from Terraform (ECR registry, IRSA role ARNs, S3 bucket)
// are injected as Jenkins global environment variables by
// scripts/bootstrap-platform.sh. The pipeline NEVER runs terraform:
// the agent has no state file, no backend config, and no need for either.

pipeline {
    agent {
        kubernetes {
            yaml """
apiVersion: v1
kind: Pod
metadata:
  labels:
    jenkins/agent: "true"
  annotations:
    # Rootless BuildKit cannot set up its nested mount/PID namespace under the
    # default AppArmor profile — RUN steps fail with
    # 'error mounting "proc" to rootfs ... operation not permitted'.
    # Scoped to the buildkit container only; the other containers keep the
    # default profile.
    container.apparmor.security.beta.kubernetes.io/buildkit: unconfined
spec:
  serviceAccountName: jenkins-agent
  # emptyDir volumes mount root-owned by default. The tools container runs
  # as UID 1000, so without fsGroup it cannot write config.json or the
  # workspace, and the build fails with "Permission denied".
  securityContext:
    fsGroup: 1000
  tolerations:
    - key: "role"
      operator: "Equal"
      value: "jenkins"
      effect: "NoSchedule"
  nodeSelector:
    eks.amazonaws.com/nodegroup: "${env.JENKINS_NODE_GROUP}"
  containers:
    - name: tools
      image: "${env.AGENT_TOOLS_IMAGE}"
      command: ["sleep"]
      args: ["infinity"]
      volumeMounts:
        - name: docker-config
          mountPath: /home/jenkins/.docker
    - name: buildkit
      image: moby/buildkit:v0.18.2-rootless
      command: ["sleep"]
      args: ["infinity"]
      securityContext:
        seccompProfile:
          type: Unconfined
        runAsUser: 1000
        runAsGroup: 1000
      env:
        - name: DOCKER_CONFIG
          value: /home/jenkins/.docker
        # REQUIRED for rootless-without-privileged. Without it buildkitd asks
        # runc for a nested process sandbox, which an unprivileged container
        # is not allowed to create, and every RUN step dies mounting /proc.
        # Trade-off: build steps are isolated by the pod boundary rather than
        # an additional per-step namespace. Acceptable here because the pod is
        # single-tenant, ephemeral, and confined to the jenkins namespace —
        # and far weaker a concession than privileged: true.
        - name: BUILDKITD_FLAGS
          value: --oci-worker-no-process-sandbox
      volumeMounts:
        - name: docker-config
          mountPath: /home/jenkins/.docker
    - name: trivy
      image: aquasec/trivy:0.58.2
      command: ["sleep"]
      args: ["infinity"]
  volumes:
    # NOTE: do NOT declare a workspace volume here. The Kubernetes plugin
    # injects its own `workspace-volume` at /home/jenkins/agent and shares it
    # across every container. Declaring a second volume at the same path gives
    # jnlp and the tool containers DIFFERENT disks, so the durable-task control
    # files jnlp writes are invisible to `tools`, and every sh step dies with
    # "process apparently never started".
    - name: docker-config
      emptyDir:
        # RAM-backed: the ECR token never touches the node's disk, and it
        # is gone the moment the pod dies. 8Mi is plenty for a config.json.
        medium: Memory
        sizeLimit: 8Mi
"""
        }
    }

    // Declared HERE so the first build works even before the JCasC job
    // definition has been applied. params.IMAGE_TAG would otherwise throw.
    parameters {
        string(name: 'IMAGE_TAG', defaultValue: '',
               description: 'Optional image tag override (default: 1.0.BUILD_NUMBER)')
    }

    options {
        timeout(time: 45, unit: 'MINUTES')
        disableConcurrentBuilds()
    }

    environment {
        NAMESPACE = "devops-app"
        // Helm stores release history as SECRETS in the target namespace by
        // default, so `helm upgrade` needs list/get on secrets. We refuse to
        // grant that: Jenkins must not be able to read app-secrets (the DB
        // password). RBAC cannot scope `list` to a single named resource, so
        // there is no middle ground.
        //
        // The configmap driver keeps release history in ConfigMaps instead —
        // which Jenkins already has permission to manage. Same functionality,
        // and the containment property survives.
        //
        // NOTE: whatever reads these releases later must use the same driver.
        // scripts/destroy.sh sets HELM_DRIVER=configmap for the app charts.
        HELM_DRIVER = "configmap"
        // AWS_REGION, ECR_REGISTRY, S3_BUCKET, BACKEND_ROLE_ARN,
        // WORKER_ROLE_ARN come from Jenkins global env (set by bootstrap).
    }

    stages {
        stage('Setup') {
            steps {
                script {
                    env.TAG = params.IMAGE_TAG?.trim() ? params.IMAGE_TAG.trim()
                                                       : "1.0.${env.BUILD_NUMBER}"
                    echo "Image tag:    ${env.TAG}"
                    echo "ECR registry: ${env.ECR_REGISTRY}"
                    echo "Region:       ${env.AWS_REGION}"
                }
                container('tools') {
                    sh 'aws sts get-caller-identity'
                }
            }
        }

        stage('Validate') {
            steps {
                container('tools') {
                    sh '''
                        set -e
                        echo "=== Helm lint ==="
                        helm lint helm/backend helm/worker helm/frontend

                        echo "=== Helm template (catches render errors) ==="
                        for c in backend worker frontend; do
                            helm template "$c" "helm/$c" \
                                --set image.registry=dummy.ecr.aws \
                                --set serviceAccount.roleArn=arn:aws:iam::000000000000:role/dummy > /dev/null
                        done

                        echo "=== Hadolint ==="
                        hadolint docker/backend/Dockerfile
                        hadolint docker/worker/Dockerfile
                        hadolint docker/frontend/Dockerfile

                        echo "=== ShellCheck ==="
                        shellcheck scripts/*.sh terraform/bootstrap-state.sh
                    '''
                }
            }
        }

        stage('ECR login') {
            steps {
                container('tools') {
                    // BuildKit reads a standard docker config.json. We write
                    // one into the shared volume using an IRSA-issued token.
                    // No stored credentials: the token lasts ~12h and dies
                    // with this pod.
                    sh '''
                        set -e
                        TOKEN=$(aws ecr get-login-password --region "$AWS_REGION")
                        AUTH=$(printf 'AWS:%s' "$TOKEN" | base64 -w0)
                        umask 077
                        cat > /home/jenkins/.docker/config.json <<EOF
{"auths":{"${ECR_REGISTRY}":{"auth":"${AUTH}"}}}
EOF
                        chmod 600 /home/jenkins/.docker/config.json
                        unset TOKEN AUTH
                        echo "Wrote docker config for ${ECR_REGISTRY}"
                    '''
                }
            }
        }

        stage('Build & Push') {
            steps {
                container('buildkit') {
                    script {
                        for (svc in ['frontend', 'backend', 'worker']) {
                            def img = "${env.ECR_REGISTRY}/vm-order-${svc}:${env.TAG}"
                            sh """
                                buildctl-daemonless.sh build \\
                                    --frontend=dockerfile.v0 \\
                                    --local context=. \\
                                    --local dockerfile=docker/${svc} \\
                                    --output type=image,name=${img},push=true
                            """
                        }
                    }
                }
            }
        }

        stage('Scan') {
            steps {
                container('trivy') {
                    script {
                        for (svc in ['frontend', 'backend', 'worker']) {
                            def img = "${env.ECR_REGISTRY}/vm-order-${svc}:${env.TAG}"
                            sh """
                                trivy image --severity CRITICAL \\
                                    --exit-code 1 --no-progress \\
                                    --format table \\
                                    ${img} | tee trivy-${svc}.txt
                            """
                        }
                    }
                }
            }
        }

        stage('Deploy') {
            steps {
                container('tools') {
                    sh '''
                        set -e
                        helm upgrade --install backend helm/backend \
                            --namespace "$NAMESPACE" \
                            --set image.registry="$ECR_REGISTRY" \
                            --set image.tag="$TAG" \
                            --set serviceAccount.roleArn="$BACKEND_ROLE_ARN" \
                            --set config.AWS_REGION="$AWS_REGION" \
                            --set config.S3_BUCKET="$S3_BUCKET" \
                            --wait --timeout 5m

                        helm upgrade --install worker helm/worker \
                            --namespace "$NAMESPACE" \
                            --set image.registry="$ECR_REGISTRY" \
                            --set image.tag="$TAG" \
                            --set serviceAccount.roleArn="$WORKER_ROLE_ARN" \
                            --set config.AWS_REGION="$AWS_REGION" \
                            --wait --timeout 5m

                        helm upgrade --install frontend helm/frontend \
                            --namespace "$NAMESPACE" \
                            --set image.registry="$ECR_REGISTRY" \
                            --set image.tag="$TAG" \
                            --wait --timeout 5m
                    '''
                }
            }
        }

        stage('Verify') {
            steps {
                container('tools') {
                    sh '''
                        set -e
                        kubectl rollout status deployment/backend  -n "$NAMESPACE" --timeout=300s
                        kubectl rollout status deployment/worker   -n "$NAMESPACE" --timeout=300s
                        kubectl rollout status deployment/frontend -n "$NAMESPACE" --timeout=300s

                        # Smoke test goes through the FRONTEND, not straight to
                        # the backend. The backend NetworkPolicy accepts traffic
                        # only from pods labelled app=frontend, so a direct call
                        # from the build agent is correctly refused. Testing via
                        # nginx also exercises the real request path.
                        FRONTEND_IP=$(kubectl get svc frontend -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}')

                        echo "=== Smoke test 1/2: nginx is serving ==="
                        curl -sf --max-time 10 "http://${FRONTEND_IP}:8080/healthz" > /dev/null
                        echo "  /healthz OK"

                        echo "=== Smoke test 2/2: nginx -> backend proxy ==="
                        curl -sf --max-time 10 "http://${FRONTEND_IP}:8080/api/health" > /dev/null
                        echo "  /api/health OK (frontend reached backend)"

                        echo ""
                        echo "=== Public URL ==="
                        kubectl get ingress -n "$NAMESPACE" \
                            -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' || true
                        echo ""

                        # NOT `kubectl get all`: that expands to a fixed list
                        # including replicationcontrollers, daemonsets,
                        # statefulsets, jobs and cronjobs. The app uses none of
                        # them and Jenkins is deliberately not permitted to list
                        # them, so `get all` errors out. Ask for what exists.
                        echo "=== Cluster state ==="
                        kubectl get deployment,replicaset,pod,service,ingress,hpa \
                            -n "$NAMESPACE"
                    '''
                }
            }
        }

        stage('Archive') {
            steps {
                container('tools') {
                    // NOTE: this S3 bucket is emptied by destroy.sh, so these
                    // are per-cycle records. The Jenkins build artifacts below
                    // are the copy you keep during the cycle; download anything
                    // you need for submission before running destroy.sh.
                    // No `|| true` on the uploads. A verification step that
                    // cannot fail is worse than no verification: these uploads
                    // were silently AccessDenied for several builds while the
                    // stage still reported success.
                    sh '''
                        set -e
                        kubectl get deployment,replicaset,pod,service,ingress,hpa \
                            -n "$NAMESPACE" > cluster-state.txt

                        for f in trivy-frontend.txt trivy-backend.txt trivy-worker.txt cluster-state.txt; do
                            if [ -f "$f" ]; then
                                aws s3 cp "$f" "s3://${S3_BUCKET}/builds/${TAG}/"
                            else
                                echo "WARNING: $f was not produced by an earlier stage"
                            fi
                        done

                        echo "=== Evidence now in S3 ==="
                        aws s3 ls "s3://${S3_BUCKET}/builds/${TAG}/"
                    '''
                }
            }
        }
    }

    post {
        failure {
            container('tools') {
                sh '''
                    echo "=== Rolling back on failure ==="
                    for r in backend worker frontend; do
                        helm rollback "$r" -n devops-app 2>/dev/null || true
                    done
                '''
            }
        }
        always {
            archiveArtifacts artifacts: 'trivy-*.txt,cluster-state.txt',
                             allowEmptyArchive: true
        }
    }
}
