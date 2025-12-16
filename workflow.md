Make an oracle free tier for life account (https://www.oracle.com/uk/cloud/free/). Recommend going for an ARM machine with 24GB RAM, 4 vCPUs and 200GB storage. 

This will be your dev machine. Make sure you register for a free IPV4 address and set up an ssh key on your machine. disable username/password login.

also recommend downloading the terminus app on your phone/tablet, running the key gen in terminus and adding that public key to your VM as well for ultimate portability 

ssh to your new machine, install homebrew, install node, install claude, install git cli, install docker, install TMUX (CRUCIAL)

ask claude to harden your instance - i run other services on my machine like my ssh jumpbox and some observability tools for some other work.

on this or your main machine, what you want to do is install spec kit. https://github.com/github/spec-kit

the reason for spec kit is none other than its ability to define a project with you clearly (doesnt have to be a greenfield) and crucially, write REALLY good tasks. What we are looking for is their great tasks -> issue workflow. 

This sets up all your work in very small clearly defined tasks that should give claude enough context work with the issue -> branch -> PR flow.

if you use run.sh within your git directory (don't start claude), the scripts will run claude in the skip permissions setting and make sure that the commits, the pushes, the sleeps (to wait for PR reviews) the documentation updates and the context clearing happens. 

I recommend setting up a discord bot that can collect alert webhooks as well. (the scripts are set up to send them)

Happy remote hacking. 