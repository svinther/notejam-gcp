
# Deploy and operate a fictive customers "legacy" app at Google Cloud
 
The fictive customers application is a Python2 FLASK 0.9 web application, notejam. 

Repository is here https://github.com/svinther/notejam (dir: flask)

It was forked from `komarserjio/notejam` and modified for cloud usage.

__Solution requirements:__ 

 1. Must be able to scale up and down 
 2. Persistent data must be secured with backups
 3. Must be resilent to datacenter failures
 4. Must be prepared for emergency migration
 5. Feature rolling updates with no downtime 
 6. Feature a multistage deployment pipeline (`development`, `testing`, `production`)
 7. Provide logging and metrics insight
 
## Solution

__App modifications__

The fictive customers application was modified as follows: 
 
 * Modify `runserver.py` to specify that flask should bind to any interface (`0.0.0.0`)
 * Add `Dockerfile` and `docker-entrypoint.sh` for "containerization"
 * Add Kubernetes manifests to directory `k8s`
 * Create a `development` branch

This repo provides Google Cloud infrastructure sourcecode for Hashicorp Terraform. 

__Provided Terraform resources__

 * A regional GKE container cluster, with 3 namespaces modelling the pipeline stages , see `terraform/gke.tf`
 * A regional Cloud SQL PostgreSQL instance,  with 3 databases modelling the pipeline stages , see `terraform/sql.tf`
 * The 3 database connection info are written to Secret objects in the corresponding Kubernetes namespaces 
 * Container Image Registry bootstrap (bucket initialization), see `terraform/container_registry.tf`
 * Cloudbuild triggers, see `terraform/cloudbuild.tf`
 * Trigger for building the application and pushing the resulting binary to the image registry
 * Trigger for deploying tag promoted images to `testing` and `production` stages


__Notes__

* Any application that holds a `Dockerfile` and k8s manifests can be used with this Infrastructure
* If more isolated environments than seperate databases and namespaces is desired, the infrastructure 
can be deployed to multiple projects, causing isolation at the project level.  

# Provisioning the infrastructure

Before putting Terraform to work
 
 * a GCP project must be created and linked to a billing account.
 * The relevant GCP API's must be enabled. 
 * Cloudbuild must be manually linked to a Github Repository. 
 * A Terraform service account must be created with all relevant roles.
 * Terraform config file must be setup.


## GCP Project creation

    gcloud projects create --name notejam
  
    #lookup the generated project id  
    gcloud projects list
    
    PROJECT_ID=notejam-xxxxxx    
    gcloud config set project $PROJECT_ID

    //link project to any billing account to enable compute / container / cloudbuild API's
    gcloud beta billing accounts list
    gcloud beta billing projects link $PROJECT_ID --billing-account=xxx


## Enable cloud APIs

    gcloud services enable compute.googleapis.com \
    container.googleapis.com \
    sqladmin.googleapis.com \
    cloudbuild.googleapis.com \
    iam.googleapis.com \
    cloudresourcemanager.googleapis.com \
    servicenetworking.googleapis.com
    
## Initialize cloud CLI    
    
Let's try Switzerland ( cloud sql: yes - https://cloud.google.com/sql/docs/postgres/locations )

    gcloud compute project-info add-metadata \
    --metadata google-compute-default-region=europe-west6,google-compute-default-zone=europe-west6-a
    gcloud init
    
    gcloud auth application-default login
    

## Cloudbuild/Github linkage

Manually use Console to connect to github from notejam gcp project, use this link
https://console.cloud.google.com/cloud-build/triggers?project=$PROJECT_ID
    
## Terraform backend

Create a storage bucket for Terraform state

    gsutil mb -l EU gs://$PROJECT_ID-tfstate
    gsutil versioning set on gs://$PROJECT_ID-tfstate
    
## Terraform config

    cd terraform
    # Edit config options in terraform.tfvars
    
## Terraform invocation    
    
Finally let Terraform do its thing    
    
    terraform init -backend-config="bucket=$PROJECT_ID-tfstate"
    terraform apply
    

## Useful extra configuration

__kubectl__

    gcloud container clusters get-credentials notejam --region europe-west6
    
__Testing from inside GKE__

It can be usefull to be able to connect to databases etc. without having to establish virtual machines or vpn's,
and since we have Kubernetes running, all we need is a nice image for testing stuff:

To avoid issues with logging into docker hub, we manually transfer the image to our private registry

    docker pull svinther/armyknife
    docker tag svinther/armyknife eu.gcr.io/$PROJECT_ID/armyknife:latest
    
    gcloud auth configure-docker
    docker push eu.gcr.io/$PROJECT_ID/armyknife:latest
    
    kubectl run -it --rm --restart=Never --image=eu.gcr.io/$PROJECT_ID/armyknife armyknife -- bash


# Operating the infrastructure

## App deployment

__Deploying new app version__
 
 The `development` branch is being tracked by cloud build, and any commit for the branch will be readily
 built, tested and the resulting image tagged with COMMIT_SHA + BRANCH_NAME.
 Then the image is pushed to image registry, and the Kubernetes deployment in the development namespace is
 updated accordingly, causing an automated rolling upgrade of the app pods.
 
__Promoting a version to testing or production__

No new images are build, the binary artifacts (Docker images) that is being auto rolled out on the development stage
is the same images that are later promoted to the testing and lastly the production stage.

Apply a tag to the desired gitcommit, with the tag name being the desired stage to be upgraded.

     git tag testing
     git push origin refs/tags/testing
 
## App scaling

To scale the number of nojam instances from the default 2x to 4 times capacity

     kubectl -n [testing|production] scale --replicas=8 deployment notejam


## Backup 
 
__Enabling backups__

    gcloud sql instances patch notejam --backup-start-time=23:15
    
__Disabling backups__

    gcloud sql instances patch notejam --no-backup
   
## CloudSQL notes
   
Initiate a failover to the standby
https://cloud.google.com/sql/docs/postgres/configure-ha#test

    gcloud sql instances failover notejam
   
To find out where backups are actually stored, the API must be used to list the backups
   
    curl -X GET \
    -H "Authorization: Bearer "$(gcloud auth print-access-token) \
    https://www.googleapis.com/sql/v1beta4/projects/$PROJECT_ID/instances/notejam/backupRuns
    
It seems that location is set to eu, meaning it is multi regional. 
https://cloud.google.com/sql/docs/postgres/locations#location-mr

It seems that it is not possible to satisfy the fictive customer backup and recovery requirements using 
Cloud SQL. See the note here:
https://cloud.google.com/sql/docs/postgres/backup-recovery/backups#default-backup-location

Consider cross region readonly replicas for disaster recovery https://cloud.google.com/sql/docs/postgres/replication/cross-region-replicas

Also only 7 days of backups is retained, according to this
https://cloud.google.com/sql/docs/postgres/backup-recovery/backups#what_backups_cost

Maintenance with downtime will occur without failover to the secondary node
https://cloud.google.com/sql/docs/postgres/maintenance
