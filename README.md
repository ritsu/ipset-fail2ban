ipset-fail2ban
===============

A small bash script to create an [ipset blacklist](http://ipset.netfilter.org/) from banned IP addresses from (multiple) 
[fail2ban jails](https://github.com/fail2ban/fail2ban), and incorporate it into an iptables rule. This project was 
inspired by [ipset-blacklist](https://github.com/trick77/ipset-blacklist), which creates ipset blacklists from 
[published blocklists](#using-ipset-fail2ban-with-published-blocklists).

## How it works
Banned IP addresses are fetched from fail2ban and written to an ipset blacklist. A rule is then added to iptables to 
DROP packets coming from any source that matches this blacklist.

The script can automatically remove blacklisted IP addresses from the fail2ban jails they originally came from. 
This helps keep iptables clean and ensures the use of ipset's fast hash table lookup for source matching.

Each time the script runs, banned IPs fetched from fail2ban are also written to a blacklist file. This file is used 
in subsequent runs to build the banned IP list. If you configure the script to automatically remove IPs from fail2ban, 
make sure this blacklist file is placed somewhere safe, since it is what the script uses to remember past banned IPs 
that have been removed from fail2ban. Since the script builds its banned IP list from both the blacklist file and 
fail2ban, and then writes this list back to the blacklist file (after removing duplicates and private IPs), the file is 
effectively self updating.

## Requirements
- **fail2ban**: If not already installed, install with `sudo apt-get install fail2ban`
- **ipset**: If not already installed, install with `sudo apt-get install ipset`

## Instructions for Debian/Ubuntu based installations
1. Grab the **ipset-fail2ban.sh** and save it somewhere that makes sense. Make it executable.
    ```
    sudo wget -O /usr/local/sbin/ipset-fail2ban.sh https://raw.githubusercontent.com/ritsu/ipset-fail2ban/master/ipset-fail2ban.sh && sudo chmod +x /usr/local/sbin/ipset-fail2ban.sh
    ```
2. You can run the script without a configuration file to test. Replace `JAIL1,JAIL2,JAIL3` with your fail2ban jails. 
Use `-h` to see a list of options.
    ```
    sudo /usr/local/sbin/ipset-fail2ban.sh -j JAIL1,JAIL2,JAIL3
    sudo /usr/local/sbin/ipset-fail2ban.sh -h
    ```
3. Grab the default configuration file.
    ```
    sudo mkdir -p /etc/ipset-fail2ban && sudo wget -O /etc/ipset-fail2ban/ipset-fail2ban.conf https://raw.githubusercontent.com/ritsu/ipset-fail2ban/master/ipset-fail2ban.conf
    ```
4. Modify **ipset-fail2ban.conf** according to your needs. Particularly,
- `JAILS` will need to be set according to your fail2ban setup
- `BLACKLIST_FILE` by default saves to `/etc/ipset-fail2ban/ipset-fail2ban.list`
- `IPSET_RESTORE_FILE` by default saves to `/etc/ipset-fail2ban/ipset-fail2ban.restore`
- `CLEANUP` is set to `false` by default, so banned IPs will remain in fail2ban jails even after being added to the 
ipset blacklist. It is recommended to set this to `true` after you have settled on a working configuration for your 
system.

5. Once your config is set, run ipset-fail2ban with the configuration file and check iptables for the blacklist rule.
    ```
    sudo /usr/local/sbin/ipset-fail2ban.sh /etc/ipset-fail2ban/ipset-fail2ban.conf
    sudo iptables -L INPUT -v --line-numbers | grep match-set

    1   5209  327K DROP     all  --  any    any     anywhere       anywhere       match-set blacklist-fail2ban src
    ```
6. Add the script to a cron job if you want it to automatically update.
    ```
    sudo crontab -e
    
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    0 0 * * * root /usr/local/sbin/ipset-fail2ban.sh /etc/ipset-fail2ban/ipset-fail2ban.conf
    ```

## Making ipset blacklist and iptables rule persistent
Since the ipset blacklist and iptables rule are stored in memory, they are lost after a reboot. A simple way to make 
them persistent is to edit `/etc/rc.local` to create the blacklist and add the rule at startup:
```
ipset restore < /etc/ipset-fail2ban/ipset-fail2ban.restore
iptables -I INPUT 1 -m set --match-set blacklist-fail2ban src -j DROP
```
You could also instead use a firewall script of your choice and packages like _iptables-persistent_ and _netfilter-persistent_. 
Just make sure the ipset blacklist is created before the blacklist rule is added to iptables.

## Inserting ipset-fail2ban rule above fail2ban rules in iptables
One of the reasons we use ipset-fail2ban is to avoid the long list of fail2ban rules in iptables. Therefore, it is 
better if the ipset-fail2ban rule is inserted before the fail2ban rules in the iptables INPUT chain. However, fail2ban 
has a tendency to insert its rules at the top of the INPUT chain whenever it restarts. We can get around this by 
changing the default rule position in fail2ban's action configs in `/etc/fail2ban/action.d/`. Depending on which 
actions your jails use, add one or more of the files:
```
sudo tee << EOF /etc/fail2ban/action.d/iptables-allports.local
[Definition]
actionstart = <iptables> -N f2b-<name>
              <iptables> -A f2b-<name> -j <returntype>
              <iptables> -I <chain> 2 -p <protocol> -j f2b-<name>
EOF
```
```
sudo tee << EOF /etc/fail2ban/action.d/iptables-multiport.local
[Definition]
actionstart = <iptables> -N f2b-<name>
              <iptables> -A f2b-<name> -j <returntype>
              <iptables> -I <chain> 2 -p <protocol> -m multiport --dports <port> -j f2b-<name>
EOF
```
If you use additional actions, create those files accordingly.

## Using ipset-fail2ban with published blocklists
Besides creating ipset blacklists from fail2ban jails, you can also create ipset blacklists from 
[published blocklists](https://github.com/firehol/blocklist-ipsets) with 
[ipset-blacklist](https://github.com/trick77/ipset-blacklist) to preemptively block bad IPs.

Both scripts can run independently on the same machine to generate two separate blacklists, which can be useful for 
keeping track of separate stats. Or, you can combine them into one blacklist by having ipset-fail2ban write to a local 
blacklist file instead of an ipset blacklist, and importing that into the ipset-blacklist script. To do that, first 
modify **ipset-fail2ban.conf**:
```
BLACKLIST_FILE="/etc/ipset-fail2ban/ipset-fail2ban.list"
IPSET_BLACKLIST=""       # Leaving this empty will prevent any of the ipset functions from running
```
Then add the following line to the BLACKLISTS array in ipset-blacklist's **ipset-blacklist.conf**:
```
BLACKLISTS=(
    "file:///etc/ipset-fail2ban/ipset-fail2ban.list"
    ...
)
```
Now simply run ipset-fail2ban before running ipset-blacklist, either manually or in a cron job.
