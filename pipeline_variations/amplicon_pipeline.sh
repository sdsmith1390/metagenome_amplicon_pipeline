#!/bin/bash

module load gparallel
module load Java/1.7.0_51
module load CDHIT/4.6.1
module load R/2.15.1
module load Biopython/1.65


DIRECTORY=/mnt/home/smithsch/Yeast
RAWDAT_DIRECTORY=$DIRECTORY/original
MAPPING_FILE=$RAWDAT_DIRECTORY/map.txt

SCRIPTS=/mnt/home/smithsch/code
RDP=/mnt/research/rdp/public
PANDASEQ=$RDP/RDP_misc_tools/pandaseq/pandaseq
CHIMERA_DB=/mnt/scratch/smithsch/DataBase_GreenGene/current_Bacteria_unaligned.fa
VSEARCH=/mnt/research/germs/Schuyler/Applications/bin/vsearch
CORES=2

## assemble paired-ends. The below parameters work well with bacterial 16S. 
OVERLAP=10 ## minimal number of overlapped bases required for pair-end assembling. Not so critical if you set the length parameters (see below)
MINLENGTH=480 #16s: "250" ## minimal length of the assembled sequence
MAXLENGTH=520 #16s: "280" ## maximum length of the assembled sequence
Q=25 ## minimal read quality score.


ls $RAWDAT_DIRECTORY/*_R*.fastq* > $RAWDAT_DIRECTORY/raw_seq_list.txt
mkdir -p $DIRECTORY/parallel_scripts/../split_fastqs
while read SEQS; 
	do NAME=`basename $SEQS | cut -d "." -f 1`; 
	mkdir -p $DIRECTORY/split_fastqs/$NAME; 
	echo "split -l 1000000 $SEQS $DIRECTORY/split_fastqs/$NAME/"; 
done < $RAWDAT_DIRECTORY/raw_seq_list.txt > $DIRECTORY/parallel_scripts/split_fastqs.sh
cat $DIRECTORY/parallel_scripts/split_fastqs.sh | parallel -j 4
ls $DIRECTORY/split_fastqs/*/* | rev | cut -d "/" -f 1 | sort -u | rev > $DIRECTORY/seqs_list.txt

mkdir -p $DIRECTORY/pandaseq/assembled/../stats
while read SEQS;
	do echo "$PANDASEQ -T $CORES -o $OVERLAP -e $Q -N -F -d rbkfms -l $MINLENGTH -L $MAXLENGTH -f $DIRECTORY/split_fastqs/*_R1_*/$SEQS -r $DIRECTORY/split_fastqs/*_R2_*/$SEQS 1> $DIRECTORY/pandaseq/assembled/$SEQS.assembled.fastq 2> $DIRECTORY/pandaseq/stats/$SEQS.assembled.stats.txt.bz2";
done < $DIRECTORY/seqs_list.txt > $DIRECTORY/parallel_scripts/pandaseq.sh
cat $DIRECTORY/parallel_scripts/pandaseq.sh | parallel -j 10
find $DIRECTORY/pandaseq/assembled -type f -size 0 -exec rm {} +
ls $DIRECTORY/pandaseq/assembled/* | rev | cut -d "/" -f 1 | rev | cut -d "." -f 1 > $DIRECTORY/seqs_list.txt

mkdir -p $DIRECTORY/quality_check/seqs_25/../chimera_removal/../final_seqs
while read SEQS;
	do echo "java -jar $RDP/RDPTools/SeqFilters.jar -Q $Q -s $DIRECTORY/pandaseq/assembled/$SEQS.assembled.fastq -o $DIRECTORY/quality_check/seqs_25 -O $SEQS; python $SCRIPTS/fastq_to_fasta.py $DIRECTORY/quality_check/seqs_25/$SEQS/NoTag/NoTag_trimmed.fastq $DIRECTORY/quality_check/seqs_25/$SEQS/$SEQS.fa";
done < $DIRECTORY/seqs_list.txt > $DIRECTORY/parallel_scripts/qc.sh
cat $DIRECTORY/parallel_scripts/qc.sh | parallel -j 20 --delay 2
cat $DIRECTORY/quality_check/seqs_25/*/*.fa > $DIRECTORY/quality_check/chimera_removal/all_combined_q25.fa

$VSEARCH --threads 20 --derep_fulllength $DIRECTORY/quality_check/chimera_removal/all_combined_q25.fa --output $DIRECTORY/quality_check/chimera_removal/all_combined_q25_unique_sort_min2.fa --sizeout --minuniquesize 5
$VSEARCH --threads 20 --uchime_denovo $DIRECTORY/quality_check/chimera_removal/all_combined_q25_unique_sort_min2.fa --chimeras $DIRECTORY/quality_check/chimera_removal/all_combined_q25_unique_sort_min2_denovo.chimera --nonchimeras $DIRECTORY/quality_check/chimera_removal/all_combined_q25_unique_sort_min2_denovo.good
$VSEARCH --threads 20 --uchime_ref $DIRECTORY/quality_check/chimera_removal/all_combined_q25_unique_sort_min2_denovo.good --nonchimeras $DIRECTORY/quality_check/chimera_removal/all_combined_q25_unique_sort_min2_denovo_ref.good --db $CHIMERA_DB

$VSEARCH --threads 20 --derep_fulllength $DIRECTORY/quality_check/chimera_removal/all_combined_q25_unique_sort_min2_denovo_ref.good --relabel "U_" --output $DIRECTORY/quality_check/chimera_removal/relabeled_denovo_ref.good

while read SEQS;
	do echo "$VSEARCH --usearch_global $DIRECTORY/quality_check/seqs_25/$SEQS/$SEQS.fa --db $DIRECTORY/quality_check/chimera_removal/all_combined_q25_unique_sort_min2_denovo_ref.good --id 0.985 --matched $DIRECTORY/quality_check/final_seqs/$SEQS\_finalized.fa";
done < $DIRECTORY/seqs_list.txt > $DIRECTORY/parallel_scripts/remapping.sh
cat $DIRECTORY/parallel_scripts/remapping.sh | parallel -j 20

mkdir -p $DIRECTORY/i_file/../demultiplex/parse_index/../bins/../empty_samples/../demultiplex_finalized; split -l 1000000 $RAWDAT_DIRECTORY/*_I*.fastq* $DIRECTORY/i_file/
perl $SCRIPTS/dos2unix.pl $MAPPING_FILE > $DIRECTORY/demultiplex/tag_file.txt
python $SCRIPTS/MiSeq_rdptool_map_parser.py $DIRECTORY/demultiplex/tag_file.txt > $DIRECTORY/demultiplex/tag_file.tag

while read I;
	do mkdir $DIRECTORY/demultiplex/parse_index/$I
	echo "java -jar $RDP/RDPTools/SeqFilters.jar --seq-file $DIRECTORY/i_file/$I --tag-file $DIRECTORY/demultiplex/tag_file.tag --outdir $DIRECTORY/demultiplex/parse_index/$I"
done < $DIRECTORY/seqs_list.txt > $DIRECTORY/parallel_scripts/demultiplex.sh
cat $DIRECTORY/parallel_scripts/demultiplex.sh | parallel -j 14
awk '{print $1}' $DIRECTORY/demultiplex/tag_file.txt | tail -n +2 > $DIRECTORY/lane_list.txt

while read LANE;
	do echo "cat $DIRECTORY/demultiplex/parse_index/*/result_DIRECTORY/$LANE/$LANE\_trimmed.fastq > $DIRECTORY/demultiplex/bins/$LANE\_trimmed.fastq"
done < $DIRECTORY/lane_list.txt > $DIRECTORY/parallel_scripts/cat_lanes.sh
cat $DIRECTORY/parallel_scripts/cat_lanes.sh | parallel -j 20

# here change lane_list to include only the ones you want in the analysis.

while read SEQS;
	do mkdir -p $DIRECTORY/demultiplex/parsed_fastas/$SEQS
	echo "python $SCRIPTS/bin_reads.py $DIRECTORY/quality_check/final_seqs/$SEQS\_finalized.fa $DIRECTORY/demultiplex/bins $DIRECTORY/demultiplex/parsed_fastas/$SEQS"
done < $DIRECTORY/seqs_list.txt > $DIRECTORY/parallel_scripts/bin_reads.sh
cat $DIRECTORY/parallel_scripts/bin_reads.sh | parallel -j 20

while read I;
	do echo "cat $DIRECTORY/demultiplex/parsed_fastas/*/$I*.fasta > $DIRECTORY/demultiplex/demultiplex_finalized/$I.fasta"
done < $DIRECTORY/lane_list.txt > $DIRECTORY/parallel_scripts/cat_bins.sh
cat $DIRECTORY/parallel_scripts/cat_bins.sh | parallel -j 20
find $DIRECTORY/demultiplex/demultiplex_finalized -type f -size 0 -exec mv -t $DIRECTORY/demultiplex/empty_samples/ {} +

mkdir -p $DIRECTORY/cdhit_clustering/master_otus/../R/../combined_seqs
python $SCRIPTS/renaming_seq_w_short_sample_name.py $DIRECTORY/cdhit_clustering/combined_seqs/sample_filename_map.txt $DIRECTORY/cdhit_clustering/combined_seqs/sequence_name_map.txt $DIRECTORY/demultiplex/demultiplex_finalized/*.fasta > $DIRECTORY/cdhit_clustering/combined_seqs/all_sequences.fa
cd-hit-est -i $DIRECTORY/cdhit_clustering/combined_seqs/all_sequences.fa -o $DIRECTORY/cdhit_clustering/combined_seqs/combined_seqs_cdhit.fasta -c 0.95 -M 200000 -T 20
python $SCRIPTS/cdhit_clstr_to_otu.py $DIRECTORY/cdhit_clustering/combined_seqs/combined_seqs_cdhit.fasta.clstr > $DIRECTORY/cdhit_clustering/master_otus/cdhit_otu_table_long.txt
Rscript $SCRIPTS/convert_otu_table_long_to_wide_format.R $DIRECTORY/cdhit_clustering/master_otus/cdhit_otu_table_long.txt $DIRECTORY/cdhit_clustering/R/cdhit_otu_table_wide.txt

java -Xmx24g -jar $RDP/RDPTools/classifier.jar classify -c 0.5 -f filterbyconf -o $DIRECTORY/cdhit_clustering/master_otus/cdhit_otu_taxa_filterbyconf.txt -h $DIRECTORY/cdhit_clustering/master_otus/cdhit_otu_taxa_filterbyconf_hierarchy.txt $DIRECTORY/cdhit_clustering/combined_seqs/combined_seqs_cdhit.fasta

python $SCRIPTS/rep_seq_to_otu_mapping.py $DIRECTORY/cdhit_clustering/combined_seqs/combined_seqs_cdhit.fasta.clstr > $DIRECTORY/cdhit_clustering/combined_seqs/combined_seqs_cdhit_rep_seq_to_cluster.map
Rscript $SCRIPTS/renaming_taxa_rep_seq_to_otus.R $DIRECTORY/cdhit_clustering/master_otus/cdhit_otu_taxa_filterbyconf.txt $DIRECTORY/cdhit_clustering/combined_seqs/combined_seqs_cdhit_rep_seq_to_cluster.map $DIRECTORY/cdhit_clustering/R/cdhit_taxa_table_w_repseq.txt

python $SCRIPTS/cdhit_clstr_to_otu.py otus_repsetOUT.fasta > test.txt

