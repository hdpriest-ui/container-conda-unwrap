---
output:
  pdf_document: default
  html_document: default
---
# PEcAn Conda Environment Setup for CARB Demo/Workshop

## Table of contents
1. [Introduction](#introduction)
2. [Setup](#setup)
3. [Dependencies](#dependencies)

## Introduction <a name="introduction"></a>

This document guides you through setting up the pre-packaged PEcAn conda environment for the CARB demo/workshop. Setup is fully automated by a single shell script that downloads the environment, unpacks it, and installs all R packages. The script takes approximately 20–40 minutes to run, after which the environment is ready to use.

---

## Setup {#setup}

Configure the AWS CLI if you have not already (Access Key and Secret Access Key will be provided separately):
```sh
aws configure
AWS Access Key ID [None]: <your-access-key>
AWS Secret Access Key [None]: <secret-key>
Default region name [None]: garage
Default output format [None]:
```

Download and run the setup script:
```sh
aws s3 cp --endpoint-url https://s3.garage.ccmmf.ncsa.cloud \
  s3://carb/environments/setup-pecan-env.sh ./

bash setup-pecan-env.sh
```

By default the environment is installed to `~/.conda/envs/pecan-all`. To install elsewhere, pass the desired path as an argument:
```sh
bash setup-pecan-env.sh /your/preferred/path
```

When the script completes, activate the environment with:
```sh
conda activate pecan-all
```

Or, activate the environment by its path:
```sh
conda activate -p /your/preferred/path
```

---

## Dependencies {#dependencies}

- **Conda**
  [Miniconda](https://www.anaconda.com/docs/getting-started/miniconda/main) is sufficient.

- **AWS CLI**
  Used to download the setup script from the NCSA S3 endpoint (`s3.garage.ccmmf.ncsa.cloud`).

- **C/C++ build tools**
  Required for R package compilation during setup. On most HPC systems these are available via a `gcc` module. If the script fails with "no C compiler found", load the appropriate module (e.g., `module load gcc`) and re-run the script.
