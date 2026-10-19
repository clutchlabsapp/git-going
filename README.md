# git-going
A library of Actions for GitHub

## Salesforce
* Salesforce backup - Use this action to automatically back up your objects, fields, flows, and other metadata from Salesforce automatically. It requires an Action Secret to be set for SF_AUTH_URL, which must be generated locally first by logging with the CLI (https://developer.salesforce.com/tools/salesforcecli) and then getting the authorized URL - BE CAREFUL as this URL will allow anyone to authenticate to Salesforce, only use it in the Action Secret:

```bash
  - sf org login web --alias prod
  - sf org auth show-sfdx-auth-url -o prod
```

## Windmill.dev
* Windmill backup - Works with the Windmill.dev CLI to backup your scripts and flows automatically. In order to use it you must first set Action Variables WM_WORKSPACE and WM_URL for your workspace id and Windmill URL, as well as an Action Secret WM_TOKEN generated in the user settings of the running user account
