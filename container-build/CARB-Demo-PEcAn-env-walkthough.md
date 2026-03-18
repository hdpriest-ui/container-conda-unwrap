---
output:
  pdf_document: default
  html_document: default
---
# PEcAn Conda Environment Setup for CARB Demo/Workshop

## Table of contents
1. [Introduction](#introduction)
2. [Obtaining the environment tarball](#obtaining)
3. [Unpack and activate the environment](#unpack-and-activate)
4. [Verify the environment](#verify)
5. [Dependencies](#dependencies)

## Introduction <a name="introduction"></a>

This document guides you through downloading the pre-packaged PEcAn conda environment from CARB S3 storage, unpacking it, and activating it. Once complete, you are ready to continue with the demo/workshop.

The environment is hosted at:
**`s3://carb/environments/pecan-all.tar.gz`**

---

## Obtaining the environment tarball {#obtaining}

You need the environment tarball from the S3 data host. Access is typically via the AWS CLI with the appropriate endpoint.

Configure the AWS CLI if you have not already (Access Key and Secret Access Key will be provided separately). Example prompt:
```sh
aws configure
AWS Access Key ID [None]: <your-access-key>
AWS Secret Access Key [None]: <secret-key>
Default region name [None]: garage
Default output format [None]:
```

Download the PEcAn environment tarball:
```sh
aws s3 cp --endpoint-url https://s3.garage.ccmmf.ncsa.cloud \
  s3://carb/environments/pecan-all.tar.gz ./
```

---

## Unpack and activate the environment {#unpack-and-activate}

If you do not already have Conda installed, use [Miniconda](https://www.anaconda.com/docs/getting-started/miniconda/install#linux) for a local user install.

The commands below assume conda environments live in the standard location: `~/miniconda3/envs` or `~/.conda/envs`. If you are new to conda, create the envs directory and unpack into it:

```sh
mkdir -p ~/.conda/envs
```

```sh
mkdir -p ~/.conda/envs/pecan-all
```

```sh
tar -xzf pecan-all.tar.gz -C ~/.conda/envs/pecan-all
```

Activate the environment and fix paths for your machine:

```sh
source ~/.conda/envs/pecan-all/bin/activate
```

```sh
conda-unpack
```

The `conda-unpack` step adjusts paths inside the environment to match your local filesystem.

To activate this environment in future sessions:

```sh
conda activate pecan-all
```

---

## Verify the environment {#verify}

Check that R is using the environment’s library path:

```sh
Rscript -e '.libPaths()'
# [1] "~/.conda/envs/pecan-all/lib/R/library" # or similar
```

You should see a path inside the unpacked conda environment (e.g. `~/.conda/envs/pecan-all/lib/R/library`).

Confirm PEcAn packages load:

```sh
Rscript -e 'library("PEcAn.workflow")'
```

or

```sh
Rscript -e 'library("PEcAn.SIPNET")'
```

If these run without errors, the environment is ready for the demo/workshop.

---

## Dependencies {#dependencies}

- **Conda**  
  This guide uses Conda for environment management. [Miniconda](https://www.anaconda.com/docs/getting-started/miniconda/main) is sufficient.

- **AWS CLI**  
  The AWS S3 CLI is used to download the environment tarball from the NCSA S3 endpoint (`s3.garage.ccmmf.ncsa.cloud`).
