# 123solar Ubuntu
123Solar Installation Script for Ubuntu




# 1. Install git if not already present
sudo apt-get install -y git

# 2. Clone the repository
git clone https://github.com/Plutoaurus/123solar-ubuntu.git

cd 123solar-ubuntu

Edit the script to add the IP Address
********IPADDRESS*******

# 3. Make the script executable
chmod +x 123solarubuntuAurora.sh

# 4. Run it as root
sudo ./123solarubuntuAurora.sh


That's it. 
The script will handle everything from there — installing packages, building aurora, setting up socat, and starting all the services.

For Aurora Power One
Port: /dev/ttyV0
Protocol: Aurora (or Power One Aurora depending on your version)
Communication options: -U25 -Y50 -w10 -a1 -d0
