// jenkins/jobs/seed.groovy — the two jobs, defined as code.
//
// Rendered into the JCasC `jobs:` block by scripts/configure-jenkins.sh and
// applied by the job-dsl plugin at startup. Neither job is ever created
// through the Jenkins UI: destroy the cluster, rebuild it, and both jobs
// reappear identically.
//
// __GITHUB_REPO_URL__ is substituted by scripts/configure-jenkins.sh from
// `terraform output github_repo_url`, so a second contributor points at their
// own fork without editing this file.
//
// It is NOT read with System.getenv(). JCasC globalNodeProperties sets Jenkins
// BUILD environment variables, which are injected into agent processes; they
// are not part of the controller JVM's process environment. System.getenv()
// therefore returns null here, the job is created with an empty remote, and
// branch indexing fails with "Cannot parse Git URI-ish: The uri was empty".

// ---------------------------------------------------------------------------
// 1. application-ci — build, test, scan, push. Never deploys.
// ---------------------------------------------------------------------------
multibranchPipelineJob('application-ci') {
    description('''CI: lint, unit tests, build, scan, push to ECR.
                   Contains NO deploy stage. Runs as jenkins-agent-ci, which
                   has no Kubernetes deploy permission.
                   Branch main pushes images and triggers application-cd;
                   pull requests build and scan but never push.''')

    branchSources {
        git {
            id('vm-order-portal')
            remote('__GITHUB_REPO_URL__')
            includes('main PR-*')
        }
    }

    factory {
        workflowBranchProjectFactory {
            scriptPath('Jenkinsfile-ci')
        }
    }

    // Webhook-driven. Polling is a fallback in case the hook is missing after
    // a cluster rebuild — scripts/register-webhook.sh normally handles that.
    triggers {
        periodicFolderTrigger {
            interval('5m')
        }
    }

    orphanedItemStrategy {
        discardOldItems {
            numToKeep(10)
        }
    }
}

// ---------------------------------------------------------------------------
// 2. application-cd — deploy an existing image. Never builds.
// ---------------------------------------------------------------------------
pipelineJob('application-cd') {
    description('''CD: deploy an image that CI already built and scanned.
                   Requires an immutable IMAGE_TAG; "latest" is rejected.
                   Contains NO build stage and has no ECR push permission.
                   Runs as jenkins-agent-cd, scoped to the devops-app namespace.''')

    parameters {
        stringParam('IMAGE_TAG', '',
            'Immutable image tag produced by CI (git short SHA). "latest" is rejected.')
        stringParam('BACKEND_DIGEST', '',  'sha256:... recorded by CI')
        stringParam('FRONTEND_DIGEST', '', 'sha256:... recorded by CI')
        stringParam('WORKER_DIGEST', '',   'sha256:... recorded by CI')
        stringParam('CI_BUILD', '',        'Originating CI build number (traceability)')
        stringParam('GIT_COMMIT_SHA', '',  'Originating git commit (traceability)')
        choiceParam('TARGET_NAMESPACE', ['devops-app'],
            'Deployment target. RBAC permits this namespace only.')
    }

    definition {
        cpsScm {
            scm {
                git {
                    remote {
                        url('__GITHUB_REPO_URL__')
                    }
                    branches('*/main')
                }
            }
            scriptPath('Jenkinsfile-cd')
        }
    }
}
