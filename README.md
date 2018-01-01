ipset-fail2ban
===============

A bash shell script to create an [ipset blacklist](http://ipset.netfilter.org/) from banned IP addresses from (multiple) [fail2ban jails](https://github.com/fail2ban/fail2ban), and incorporate it into an iptables rule.

The motivation for this came from wanting a simple way to permanently ban IP addresses from certain fail2ban jails. In addition to avoiding arbitrarily long _bantime_ settings in fail2ban, this also cuts down on the long list of fail2ban rules that can build up in iptables, which takes advantage of ipset's use of hashtables for faster lookups.

This project was inspired by [ipset-blacklist](https://github.com/trick77/ipset-blacklist) and can be used alongside or together with it to incorporate publicly available blacklists. See instructions further [below](#using-ipset-fail2ban-with-public-blacklists).

## Requirements
- **fail2ban**: If not already installed, install with `sudo apt-get install fail2ban`
- **ipset**: If not already installed, install with `sudo apt-get install ipset`

## Instructions for Debian/Ubuntu based installations
1. Grab the bash script and save it somewhere that makes sense. Make it executable.
```
sudo wget -O /usr/local/sbin/ipset-fail2ban.sh https://raw.githubusercontent.com/ritsu/ipset-fail2ban/master/ipset-fail2ban.sh && sudo chmod +x /usr/local/sbin/ipset-fail2ban.sh
```
2. You can run the script without a configuration file to test it. Replace `JAIL1,JAIL2,JAIL3` with your fail2ban jails.
```
sudo /usr/local/sbin/ipset-fail2ban.sh -j JAIL1,JAIL2,JAIL3
```
3. Grab the default configuration file.
```
sudo mkdir -p /etc/ipset-fail2ban && sudo wget -O /etc/ipset-fail2ban/ipset-fail2ban.conf https://raw.githubusercontent.com/ritsu/ipset-fail2ban/master/ipset-fail2ban.conf
```
4. Modify _ipset-fail2ban.conf_ according to your needs. Particularly,
- `JAILS` will need to be set according to your fail2ban setup
- `BLACKLIST_FILE` by default saves to `/etc/ipset-fail2ban/ipset-fail2ban.list`
- `IPSET_RESTORE_FILE` by default saves to `/etc/ipset-fail2ban/ipset-fail2ban.restore`

Once your config is set, run it and check iptables for the blacklist rule.
```
sudo /usr/local/sbin/ipset-fail2ban.sh /etc/ipset-fail2ban/ipset-fail2ban.conf
sudo iptables -L INPUT -v --line-numbers | grep match-set

1   5209  327K DROP     all  --  any    any     anywhere         anywhere         match-set fail2ban-blacklist src
```
5. If you are happy with the results, remember to make the rule persistent with _iptables-persistent_ or whichever script you use to manage your firewall.
6. Add the script to a cron job if you want it to automatically update.
```
sudo crontab -e
0 0 * * * /usr/local/sbin/ipset-fail2ban.sh /etc/ipset-fail2ban/ipset-fail2ban.conf
```

## Inserting ipset-fail2ban rule above fail2ban rules in iptables
One of the reasons we use ipset-fail2ban is to avoid the long list of fail2ban rules in iptables. Therefore, it is better if the ipset-fail2ban rule is inserted before the fail2ban rules in the iptables INPUT chain. However, fail2ban has a tendency to insert its rules at the top of the INPUT chain whenever it restarts. We can get around this by changing the default rule position in fail2ban's action configs in `/etc/fail2ban/action.d/`. Depending on which actions your jails use, add one or more of the files:
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

## Using ipset-fail2ban with public blacklists
Besides creating a blacklist from IP addresses that have been blocked by fail2ban, you can also create a blacklist from publicy available blacklists to preemptively black bad IPs. [Trick77's ipset-blacklist](https://github.com/trick77/ipset-blacklist) is an easy way to add publicly available blacklists to your local ipset blacklist. 

Both scripts can run separately on the same machine to generate two separate blacklists, which can be useful for keeping track of separate stats. Or, you can combine them into one blacklist by having **ipset-fail2ban** write to a local blacklist file instead of an ipset blacklist, and importing that into the **ipset-blacklist** script. To do that, first modify `ipset-fail2ban.conf`:
```
BLACKLIST_FILE="/etc/ipset-fail2ban/ipset-fail2ban.list"
IPSET_BLACKLIST=""       # Leaving this empty will prevent any of the ipset functions from running
```
Then add the following line to ipset-blacklist's `ipset-blacklist.conf`:
```
BLACKLISTS=(
    ...
    "file:///etc/ipset-fail2ban/ipset-fail2ban.list"
    ...
)
```
Now simply run ipset-fail2ban _before_ running ipset-blacklist, either manually or as a cron job.
