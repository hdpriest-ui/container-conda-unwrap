# PEcAn Environment Build

Run all commands from this directory (`container-build/`).

## 1. Build the container

```bash
apptainer build pecan-build-rocky8.sif pecan-build-rocky8.def
```

## 2. Run the install

```bash
apptainer run --env PECAN_VERSION=1.10 --bind ~/envs:/mnt/envs --bind ~/packed:/mnt/packed ./pecan-build-rocky8.sif
```

Output: `~/packed/pecan-all-1.10.tar.gz`

Logs are written to `logs/` in the working directory.

## 3. Upload to S3

```bash
aws s3 cp --endpoint-url https://s3.garage.ccmmf.ncsa.cloud ~/packed/pecan-all-1.10.tar.gz s3://carb/environments/pecan-all-1.10.tar.gz
```

## 4. Deploy at destination

Download `setup-pecan-env.sh` and run:

```bash
bash setup-pecan-env.sh 1.10
```

An optional second argument sets the install path (default: `~/.conda/envs/pecan-all`):

```bash
bash setup-pecan-env.sh 1.10 /path/to/envs/pecan-all
```
