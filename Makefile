include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-istoreos-sms
PKG_VERSION:=2.0.0
PKG_RELEASE:=1
PKG_MAINTAINER:=Lkxu <61963176+mikutea@users.noreply.github.com>

LUCI_TITLE:=Modern LuCI SMS viewer with CNMI storage-mode health check
LUCI_DESCRIPTION:=Read stored SMS messages with sms-tool and diagnose or repair CNMI delivery mode.
LUCI_PKGARCH:=all
LUCI_DEPENDS:=+sms-tool

define Package/luci-app-istoreos-sms/conffiles
/etc/config/istoreos_sms
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
