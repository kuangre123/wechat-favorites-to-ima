from setuptools import find_packages, setup


setup(
    name="wechat-favorites-to-ima",
    version="0.1.1",
    description="Clean WeChat Favorites article links and prepare ima batch import files.",
    long_description=open("README.md", encoding="utf-8").read(),
    long_description_content_type="text/markdown",
    author="kuangre123",
    url="https://github.com/kuangre123/wechat-favorites-to-ima",
    packages=find_packages(),
    python_requires=">=3.9",
    entry_points={
        "console_scripts": [
            "wechat-favorites-to-ima=wechat_favorites_to_ima.cli:main",
            "wechat-favorites-progress=wechat_favorites_to_ima.progress:main",
        ],
    },
)
