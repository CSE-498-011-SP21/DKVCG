docker run --name dkvcg_gpu_test --gpus all -v $(pwd):/dkvcg -it dkvcg
docker rm dkvcg_gpu_test