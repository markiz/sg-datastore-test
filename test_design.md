# Test design

Attributes:

* manufacturers sku
* warehouse
* condition (new, damaged) there is a list of potential conditions in Magento.
* source of inventory (dss, consignment)
* price
* count

Queries:
* retrieve lowest cost for manu sku/condition/source of inventory
* multi capture across manu sku/condition, or manu sku/condition/source of inventory
