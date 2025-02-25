# ----- Configure the Docker & AWS Providers ------
terraform {
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0.2"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.14"
    }
  }

}

provider "docker" {}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Purpose = "Production"
    }
  }
}