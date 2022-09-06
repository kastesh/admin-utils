# admin-utils
## route53.sh - update TXT record in Route53 zone
The script is used while getting Let's Encrypt certificate via DNS-1 challenge type.
### Configuration
*I use Centos 7/8 on most servers and all examples will be given under this OS.
But I think script will be working at any OS with installed aws cli and dehydrated.*

Install aws cli tool:
```
pip3 install awscli
```
And configure it:
```
aws configure
```
You can find full recommendations and description in this article:
[Configuring the AWS CLI](https://docs.aws.amazon.com/cli/latest/userguide/cli-chap-configure.html)
__Notice__: You will need an account with access to delete and create records in the zone, as well as with the ability to get a list of available zones in Route53.

Install dehydrated utility:
```
yum install dehydrated -y
```

Install scripts:
```
cd /usr/local/bin
git clone https://github.com/kastesh/admin-utils
```

Configure challange type and hook usage in the dehydrated config /etc/dehydrated/config:
```
DOMAINS_TXT="${BASEDIR}/domains.txt"
HOOK="${BASEDIR}/hook.sh"
CHALLENGETYPE="dns-01"
```

Configure domain records ${BASEDIR}/domains.txt:
```
DOMAINNAME *.DOMAINNAME
```
You need to script calls in hook.sh file:
- while update or create new certificate (deploy_challenge)
- while finished request (clean_challenge)
Add the following script calls at file ${BASEDIR}/hook.sh:
```
deploy_challenge() {
...
/usr/local/bin/admin-utils/route53.sh -c -z ${DOMAIN} -r _acme-challenge -t ${TOKEN_VALUE} -v
...
}
clean_challenge() {
...
/usr/local/bin/admin-utils/route53.sh -d -z ${DOMAIN} -r _acme-challenge -v
...
}
```
All done! You can request a new certificate.
### Options
```
Usage: route53.sh -c|-d -z DOMAINNAME -t TOKEN -r RECORD
Options:
 -h - show help message
 -v - enable debug mode
 -c - create txt record in the DOMAIN
 -d - delete txt record in the DOMAIN
 -t - TOKEN value
 -r - RECORD name (for Let's Encrypt )
```
