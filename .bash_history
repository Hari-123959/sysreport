sudo apt update && sudo apt upgrade -y
[200~cd ~/repositoryname~
cd ~/repositoryname
wget -O makecontainers.sh https://github.com/zonzorp/COMP2137/raw/main/makecontainers.sh
chmod +x makecontainers.sh
./makecontainers.sh --prefix server --count 2 --fresh
cd ~
mkdir -p yourreponame   # or clone your actual github repo here if you already made one
cd yourreponame
sudo reboot
