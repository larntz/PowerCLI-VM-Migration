# PowerCLI-VM-Migration-Functions

Functions to migration VMs to new hosts and datastores. The functions were used for a specific migration and make the assumptions below. Wanted to post it so it could be used as a reference or starting point for others. 

## Overview

Script reads a CSV file with virtual machine names, destination host, and [optionally] a destination datastore or datastore cluster. See [sample CSV](https://github.com/larntz/PowerCLI-VM-Migration-Functions/blob/master/sample-migration.csv) in repo. 

## Assumptions

* VMs are being migrated within the same vCenter. 
* VMs can optionally be moved to a new host only or new host and new datastore. 
* Let work for placement was done in advance and used to create a CSV file (unneeded columns will be ignored). 
* You must be logged into the correct vCenter (and only that vCenter if there may be name collisions) before running the script.


