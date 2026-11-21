# Test resources for the `deleteme` cleanup job (issue #2)

## Live test, 2026-11-21 (jobrun `deleteme-live-1`, image v8, `DRY_RUN=false` on that run only)

| Resource | Outcome | State after |
|---|---|---|
| `ce-test-vpc-a`, `ce-test-a-sn`, `ce-test-a-pgw` | `DELETED` (detach → subnet → gateway → VPC) | gone; recreate with the commands below |
| `ce-test-proj` | `DELETED` to reclamation | in reclamation (7 days); restore with `ibmcloud resource reclamation-restore <id>` |
| `ce-test-vpc-b` | `SKIP_TAGS` (no `deleteme`) | still there |
| `ce-test-vpc-c` | `SKIP_TAGS` (no `owner:ryantiffany`) | still there |
| `ce-test-vpc-d` | `SKIP_CHILD` (`ce-test-d-sn` lacks `deleteme`) | still there |
| `ce-test-d-sn` | `SKIP_TAGS` | still there |

The original inventory follows.

Created 2026-11-21 in ca-tor, resource group `cloud-techsales`, zone `ca-tor-1`.
No VMs and no data. The public gateway comes with an auto-created floating IP (search shows it as
`ce-test-a-pgw`, type `floating-ip`, untagged), which is released when the gateway is deleted.

| Resource | Type | ID | Tags | Expected outcome |
|---|---|---|---|---|
| `ce-test-vpc-a` | vpc | `r038-3e0724d4-76de-4e40-a53a-d0db307dd6bc` | deleteme, owner:ryantiffany | deleted (cascade) |
| `ce-test-a-sn` | subnet in vpc-a | `02q7-e0b18af9-2a7e-4543-bc1d-e3b4900cb238` | deleteme, owner:ryantiffany | deleted (cascade) |
| `ce-test-a-pgw` | public gateway in vpc-a, attached to `ce-test-a-sn` | `r038-f52e0a66-722e-4716-973b-e69687a90a9d` | deleteme, owner:ryantiffany | detached, deleted (cascade) |
| `ce-test-vpc-b` | vpc | `r038-76e75773-ef87-4fb8-8f87-51ff5f881cea` | owner:ryantiffany | `SKIP_TAGS` |
| `ce-test-vpc-c` | vpc | `r038-524d8a42-51bb-42f0-9e7e-8b49ca30c653` | deleteme | `SKIP_TAGS` |
| `ce-test-vpc-d` | vpc | `r038-d572afea-9dce-4393-88af-3371a1c591f3` | deleteme, owner:ryantiffany | `SKIP_CHILD` (because of d-sn) |
| `ce-test-d-sn` | subnet in vpc-d | `02q7-c4fec877-b303-48f5-8742-728878d2b997` | owner:ryantiffany | blocks vpc-d |
| `ce-test-proj` | Code Engine project | `d6095178-b1de-4861-898a-cd0035a2b236` | deleteme, owner:ryantiffany | deleted to reclamation |

Check them: `ibmcloud resource search 'name:ce-test*' --output json | jq -r '.items[] | [.name,.type,(.tags|join(";"))] | @tsv'`

## Recreate

The script used is reproduced here; run it from a logged-in session.

```bash
RG=cloud-techsales; Z=ca-tor-1; BOTH="deleteme,owner:ryantiffany"
ibmcloud target -r ca-tor -g "$RG"
tag() { ibmcloud resource tag-attach --tag-names "$2" --resource-id "$1" -q; }
# vpc:    ibmcloud is vpc-create NAME --resource-group-name "$RG" --output JSON   (tag .crn)
# subnet: ibmcloud is subnet-create NAME VPC_ID --zone "$Z" --ipv4-address-count 16 --resource-group-name "$RG" --output JSON
# pgw:    ibmcloud is public-gateway-create NAME VPC_ID "$Z" --resource-group-name "$RG" --output JSON
#         ibmcloud is subnet-update SUBNET_ID --pgw PGW_ID
# proj:   ibmcloud ce project create --name ce-test-proj --no-select --tag deleteme --tag owner:ryantiffany
```

## Tear down (by hand)

```bash
ibmcloud target -r ca-tor
ibmcloud is subnet-public-gateway-detach ce-test-a-sn --vpc ce-test-vpc-a -f
ibmcloud is subnet-delete ce-test-a-sn --vpc ce-test-vpc-a -f
ibmcloud is public-gateway-delete ce-test-a-pgw --vpc ce-test-vpc-a -f
ibmcloud is subnet-delete ce-test-d-sn --vpc ce-test-vpc-d -f
# wait for the subnets/gateway to finish deleting, then:
for v in a b c d; do ibmcloud is vpc-delete ce-test-vpc-$v -f; done
ibmcloud ce project delete --name ce-test-proj --hard -f
```
