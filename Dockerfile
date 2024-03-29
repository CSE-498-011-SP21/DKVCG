FROM nvidia/cuda:11.2.1-devel-ubuntu20.04

ENV DEBIAN_FRONTEND=noninteractive
ENV LD_LIBRARY_PATH=/usr/local/lib

RUN apt update && apt install -y apt-transport-https ca-certificates gnupg software-properties-common build-essential git curl zip unzip tar pkg-config wget bzip2 libtbb-dev libboost-all-dev
RUN wget -O - https://apt.kitware.com/keys/kitware-archive-latest.asc 2>/dev/null | gpg --dearmor - | tee /etc/apt/trusted.gpg.d/kitware.gpg >/dev/null
RUN apt-add-repository 'deb https://apt.kitware.com/ubuntu/ focal main' && apt-get update && apt install -y cmake

RUN wget https://github.com/ofiwg/libfabric/releases/download/v1.9.1/libfabric-1.9.1.tar.bz2 && \
    bunzip2 libfabric-1.9.1.tar.bz2 && tar xf libfabric-1.9.1.tar && cd libfabric-1.9.1 && ./configure && \
    make -j && make install

RUN mkdir /root/.ssh

COPY docker_rsa /root/.ssh/id_rsa

COPY docker_rsa.pub /root/.ssh/id_rsa.pub

RUN chmod 600 /root/.ssh/id_rsa

RUN touch /root/.ssh/known_hosts

RUN ssh-keyscan github.com >> /root/.ssh/known_hosts

#COPY . /dkvcg

#WORKDIR /dkvcg

#RUN bash ./build.sh