cloud1-terraform/
├── main.tf                 # Point d'entrée : appelle les modules
├── variables.tf            # Déclaration des variables du root module
├── outputs.tf               # Ce qu'on expose après apply (IPs, etc.)
├── terraform.tfvars         # Valeurs concrètes des variables (gitignored si sensible)
├── providers.tf              # Config du provider azurerm
├── .gitignore
│
└── modules/
    ├── network/
    │   ├── main.tf           # VNet, subnets, NSG
    │   ├── variables.tf
    │   └── outputs.tf         # expose subnet_ids, nsg_ids...
    │
    ├── vm/
    │   ├── main.tf            # définit UNE VM générique (web ou db)
    │   ├── variables.tf       # name, size, subnet_id, ssh_key...
    │   └── outputs.tf          # expose l'IP privée/publique de la VM
    │
    └── loadbalancer/
        ├── main.tf
        ├── variables.tf
        └── outputs.tf